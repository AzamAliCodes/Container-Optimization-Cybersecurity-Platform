#!/usr/bin/env python3
"""Phase 5 — offline capacity model (docs/scaling-strategy.md §4, report §4).

REPRODUCIBILITY CONTRACT: this script is the single source of truth for every
capacity / improvement-ratio number quoted in docs/final-benchmark-report.md,
docs/scaling-strategy.md and README. Those documents must never quote a number
this script does not emit. Rerun after editing any constant below:

    python3 benchmark/model.py          # JSON + table to stdout

MODEL (mirrors the Appendix A exhaustion definition used by 04-ramp.js):
A host holds N session-pairs while ALL of these hold:

  1. RAM      HostOverhead + N * PairRAM <= EXHAUST_MEM_FRAC * MemTotal
              (PairRAM = cgroup limit sum for the optimised profile = worst-case
               committed; measured working-set for legacy which had no limits)
  2. CPU      HostCores + N * IdleCores + BurstCredit(N) <= EXHAUST_CPU_FRAC * vCPU
              Burst credit is granted only while N < BURST_TRIGGER_FRAC * (CPU
              bound); near saturation an idle run must assume concurrent bursts.
  3. PIDs     N * PairPids <= PID_CEILING                      [ASSUMPTION]
  4. DISK     DiskBase + ImageOnce + N * MarginalDisk <= UsableDisk - Reserve
              (image cost paid ONCE with shared/prefetched layers; per-session
               marginal delta = writable layer, FR-16)

Max pairs = floor(min of the four bounds). The cold-start SLA (<=10 s target)
is reported as a separate service-level check, NOT folded into the exhaustion
count — consistent with 04-ramp.js, where a healthcheck timeout trips the run
but sustained-load tests use already-running sessions.

CONSTANT PROVENANCE — every value is either MEASURED on the Phase 0 host
"(M)", hard-derived from limits.env "(L)", or an engineering estimate
"[ASSUMPTION] (A)". (A) values MUST be replaced by live Phase 5 measurements
from the SAME host before sign-off (report §6 gate G1/G2/G4).
"""

import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys

# ---------------- dynamic system detection & SSoT loaders ---------------------
def detect_host():
    """Detect current host specs from the live system."""
    ram_gib = 8.0
    try:
        if platform.system() == 'Darwin':
            out = subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True).strip()
            ram_gib = round(int(out) / (1024**3), 1)
        elif os.path.exists('/proc/meminfo'):
            with open('/proc/meminfo') as f:
                for line in f:
                    if line.startswith('MemTotal:'):
                        kb = int(line.split()[1])
                        ram_gib = round(kb / (1024**2), 1)
                        break
    except Exception:
        pass

    vcpu = os.cpu_count() or 8

    disk_gib = 60
    try:
        stat = shutil.disk_usage('/')
        disk_gib = round(stat.total / (1024**3))
    except Exception:
        pass

    return {
        "name": f"Current host ({platform.node() or 'detected'})",
        "vcpu": vcpu,
        "ram_gib": ram_gib,
        "disk_gib": disk_gib,
    }


def read_limits_env():
    """Read limits from orchestrator/limits.env SSoT."""
    limits_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'orchestrator', 'limits.env')
    out = {}
    if os.path.exists(limits_file):
        with open(limits_file, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    m = re.match(r'^([A-Z_]+)=(\S+)', line)
                    if m:
                        out[m.group(1)] = m.group(2)
    return out


def parse_mem_mb(val, default):
    if not val:
        return default
    s = str(val).lower()
    if s.endswith('g'):
        return float(s[:-1]) * 1024
    if s.endswith('m'):
        return float(s[:-1])
    try:
        return float(s)
    except ValueError:
        return default


def read_measurements():
    """Read measured baseline and optimized footprints from docs/before-after-measurements.json."""
    meas_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'docs', 'before-after-measurements.json')
    if os.path.exists(meas_file):
        try:
            with open(meas_file, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            pass
    return None

_limits = read_limits_env()
_meas = read_measurements()

# ---------------- hosts ------------------------------------------------------
# "dev" = the host both stacks were measured on (2026-10-01): macOS, 8 vCPU,
# 8 GiB, Docker Desktop 29.8.0. NOTE this host overcommits memory (~3.4 GB
# observed compressed), so a legacy pair with no limits can borrow slack that the
# model does not represent — the measured concurrency ratio was 1.7x (37 -> 62).
# "reference" = PRD §11 [ASSUMPTION] spec — numbers are model projections only.
HOSTS = {
    "current":   detect_host(),
    "dev":       {"name": "Dev host (measured 2026-10-01)", "vcpu": 8, "ram_gib": 8,
                  "disk_gib": 60},
    "reference": {"name": "Reference host (PRD §11 [ASSUMPTION])", "vcpu": 8, "ram_gib": 32,
                  "disk_gib": 250},
}

# ---------------- exhaustion thresholds (PRD Appendix A) ---------------------
# MUST match the harness defaults in benchmark/lib.sh (EXHAUST_MEM_FRAC=0.92,
# EXHAUST_CPU_PCT=90) or the model projects a different exhaustion point than the
# ramp actually measures.
EXHAUST_MEM_FRAC = 0.92    # matches lib.sh EXHAUST_MEM_FRAC
EXHAUST_CPU_FRAC = 0.90    # "host CPU sustained >90% for 60s" (lib.sh EXHAUST_CPU_PCT)
BURST_TRIGGER_FRAC = 0.80  # grant burst credit only below 80% of the CPU bound

# ---------------- host overhead ----------------------------------------------
HOST_RAM_GIB = 1.0        # containerd + dockerd + monitoring stack (cAdvisor/Prom/Grafana)
HOST_CORES_IDLE = 0.25    # (A) steady-state daemon load

# ---------------- per-pair profiles ------------------------------------------
# LEGACY — measured on this host 2026-10-01 under an identical protocol to the
# optimised stack; see docs/before-after-measurements.{md,json}. Legacy runs with
# NO resource limits, so `has_limits=False` below and the host's memory
# overcommit applies (this is what caps the achievable concurrency ratio).
# Dynamic SSoT values derived from limits.env:
_opt_ram_mb = (parse_mem_mb(_limits.get('ATTACKER_MEMORY'), 512) +
               parse_mem_mb(_limits.get('TARGET_MEMORY'), 256))
_opt_cpus = (float(_limits.get('ATTACKER_CPUS', 1.0)) +
             float(_limits.get('TARGET_CPUS', 0.5)))
_opt_pids = (int(_limits.get('ATTACKER_PIDS_LIMIT', 100)) +
             int(_limits.get('TARGET_PIDS_LIMIT', 50)))

# Measured idle values from canonical docs/before-after-measurements.json if available:
_legacy_idle_ram = 446.5
_opt_idle_ram = 45.4
_legacy_img_gib = 4.49
_opt_img_gib = 0.60
if _meas:
    try:
        _legacy_idle_ram = _meas["idle_footprint_mib"]["legacy"]["pair_total"]
        _opt_idle_ram = _meas["idle_footprint_mib"]["optimized"]["pair_total"]
        _legacy_img_gib = (_meas["images"]["legacy_attacker"]["size_mib"] +
                           _meas["images"]["legacy_target"]["size_mib"]) / 1024.0
        _opt_img_gib = (_meas["images"]["opt_attacker"]["size_mib"] +
                        _meas["images"]["opt_target"]["size_mib"]) / 1024.0
    except (KeyError, TypeError):
        pass

LEGACY = {
    "pair_ram_mib": _legacy_idle_ram,     # (M) measured idle: 401.5 attacker + 45.0 target
    "pair_cores_idle": 0.30,   # (A) PRD §5 "2-5% steady-state" per container × 2 + drift
    "burst_cores": 2.0,        # (A) unbounded: top-10 Kali box can saturate ≥2 cores
    "pair_pids": 150,          # (A) measured 15 procs/pair idle, 3x burst headroom
    "marginal_disk_mib": 400,  # (A) writable layer growth + per-session artifacts
    "image_once_gib": _legacy_img_gib,    # (M) measured legacy images
    "boot_base_ms": 30000,     # (A) PRD §5 cold-start baseline 25-40 s → median 30 s
}
# OPTIMISED — bounded by orchestrator/limits.env (committed = limit sum) and the
# Phase 1 design (tini+ttyd-only idle set, php -S target, FR-16 shared layers).
OPT = {
    "pair_ram_mib": _opt_ram_mb,   # (L) dynamically derived from limits.env
    "pair_ram_mib_measured": _opt_idle_ram,  # (M) dynamically loaded from measurements
    "pair_cores_idle": 0.03,     # (A) ≤1% KPI × 2 containers, rounded up
    "burst_cores": _opt_cpus,          # (L) dynamically derived from limits.env
    "pair_pids": _opt_pids,            # (L) dynamically derived from limits.env
    "marginal_disk_mib": 50,     # (A) §5 / FR-16 KPI ceiling — verify via gate G4
    "image_once_gib": _opt_img_gib,      # (M) dynamically derived from measurements
    "boot_base_ms": 2500,        # (M) measured 4.4s healthcheck-gated; 2.5s floor
}
BOOT_PER_PAIR_MS = 150           # (A) boot contention slope, both profiles
# (A) per-host process-table budget: kernel pid_max headroom minus daemon/system
# usage, divided by a ~3× safety factor for burst overlap (jruby/apache forks).
# Legacy had NO pids-limit so this ceiling applied to BOTH profiles equally.
PID_CEILING = 6000
DISK_RESERVE_GIB = 10         # headroom before "no space left" provisioning failures
COLD_START_SLA_MS = 10_000    # §5 target (optimised) — service-level check


def solve(profile, host, has_limits):
    ram_bound = (EXHAUST_MEM_FRAC * host["ram_gib"] * 1024 - HOST_RAM_GIB * 1024) \
        / profile["pair_ram_mib"]

    cpu_budget = EXHAUST_CPU_FRAC * host["vcpu"] - HOST_CORES_IDLE
    n_cpu = cpu_budget / profile["pair_cores_idle"]

    def cpu_ok(n):
        demand = HOST_CORES_IDLE + n * profile["pair_cores_idle"]
        if n >= BURST_TRIGGER_FRAC * n_cpu:
            demand += n * profile["burst_cores"]
        return demand <= EXHAUST_CPU_FRAC * host["vcpu"]
    n = int(n_cpu)
    while not cpu_ok(n) and n > 0:
        n -= 1
    cpu_bound = n

    pid_bound = PID_CEILING / profile["pair_pids"]

    disk_avail = host["disk_gib"] - DISK_RESERVE_GIB - profile["image_once_gib"]
    disk_bound = disk_avail * 1024 / profile["marginal_disk_mib"]

    bounds = {"ram": math.floor(max(0, ram_bound)),
              "cpu": math.floor(max(0, cpu_bound)),
              "pids": math.floor(pid_bound),
              "disk": math.floor(max(0, disk_bound))}
    max_pairs = min(bounds.values())
    binding = min(bounds, key=bounds.get)

    sla_ms = profile["boot_base_ms"] + BOOT_PER_PAIR_MS * max_pairs
    return {
        "bounds": bounds,
        "max_pairs": max_pairs,
        "binding_constraint": binding,
        "coldstart_at_max_ms": sla_ms,
        "coldstart_sla_met": bool(has_limits and sla_ms <= COLD_START_SLA_MS),
    }


def main():
    result = {}
    for hkey, host in HOSTS.items():
        leg = solve(LEGACY, host, has_limits=False)
        opt = solve(OPT, host, has_limits=True)
        ratio = round(opt["max_pairs"] / leg["max_pairs"], 1) if leg["max_pairs"] else None
        result[hkey] = {"host": host, "legacy": leg, "optimized": opt,
                        "improvement_ratio": ratio,
                        "meets_3x_target": (ratio or 0) >= 3.0}

    json.dump(result, sys.stdout, indent=2)
    print()
    print(f"{'host':<38} {'legacy':>6} {'bind':>6} {'opt':>4} {'bind':>6} {'ratio':>6} {'>=3x':>5}")
    for hkey, r in result.items():
        print(f"{r['host']['name']:<38} {r['legacy']['max_pairs']:>6} "
              f"{r['legacy']['binding_constraint']:>6} {r['optimized']['max_pairs']:>4} "
              f"{r['optimized']['binding_constraint']:>6} "
              f"{str(r['improvement_ratio']) + 'x':>6} "
              f"{'YES' if r['meets_3x_target'] else 'no':>5}")
        print(f"  bounds legacy={r['legacy']['bounds']} opt={r['optimized']['bounds']}")
        print(f"  cold-start @ max: legacy {r['legacy']['coldstart_at_max_ms']} ms / "
              f"opt {r['optimized']['coldstart_at_max_ms']} ms "
              f"(SLA {COLD_START_SLA_MS} ms: opt met={r['optimized']['coldstart_sla_met']})")

    print()
    print("=" * 78)
    print("CAVEAT — the 'dev' row is a MODEL PROJECTION, not a measurement.")
    print("Measured on this same host 2026-10-01: legacy 37 pairs, optimized 62 pairs")
    print("(1.7x). The model disagrees because it charges the legacy pair its measured")
    print("working set (446.5 MiB, unlimited) while charging the optimized pair its")
    print("COMMITTED QUOTA (768 MiB), and it assumes RAM is a hard ceiling. This host")
    print("overcommits: macOS compressed ~3.4 GB and ran legacy to 37 pairs = ~16.5 GB")
    print("of working set on an 8 GiB machine. On a host without overcommit the RAM")
    print("bound would bind and the model would be the better predictor.")
    print("For this host, trust docs/before-after-measurements.md over this projection.")
    print("=" * 78)


if __name__ == "__main__":
    main()
