#!/usr/bin/env bash
# 05-report — aggregate the per-run JSON artifacts into a single markdown report
# (PRD Appendix B test matrix) plus a machine-readable summary JSON.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

RUN_DIR="$1"          # e.g. benchmark/reports/run-<ts>
mkdir -p "$RUN_DIR"

python3 - "$RUN_DIR" <<'PY'
import json, os, sys, glob
rd = sys.argv[1]

def load(name):
    p = os.path.join(rd, name)
    if not os.path.exists(p):
        return {}
    with open(p) as f:
        return json.load(f)

img = load("images.json")
cs  = load("coldstart.json")
idle= load("idle.json")
ramp= load("ramp.json")

summary = {
    "attacker_size_mib": img.get("attacker_size_mib"),
    "target_size_mib":   img.get("target_size_mib"),
    "coldstart_median_ms": cs.get("median_ms"),
    "idle_cpu_pct_median":  idle.get("idle_cpu_pct_median"),
    "idle_ram_mib_median":  idle.get("idle_ram_mib_median"),
    "idle_procs_median":    idle.get("idle_procs_median"),
    "max_concurrent_pairs": ramp.get("max_pairs"),
    "exhaustion_trigger":   ramp.get("exhaustion_trigger"),
}
with open(os.path.join(rd, "summary.json"), "w") as f:
    json.dump(summary, f, indent=2)

def row(label, key, target=None):
    v = summary.get(key)
    tgt = f" / target {target}" if target else ""
    return f"| {label} | {v if v is not None else 'n/a'}{tgt} |"

md = []
md.append("# Phase 0 Baseline Report (legacy stack)\n")
md.append(f"Run directory: `{rd}`  ")
md.append(f"Image set: attacker=`{img.get('attacker_image','platform/attacker:legacy')}`, "
          f"target=`{img.get('target_image','platform/target:legacy')}`\n")
md.append("## Measured (Appendix B test matrix)\n")
md.append("| Metric | Value |")
md.append("|---|---|")
md.append(row("Attacker image size (MiB)", "attacker_size_mib"))
md.append(row("Target image size (MiB)", "target_size_mib"))
md.append(row("Cold-start median (ms)", "coldstart_median_ms"))
md.append(row("Idle CPU median (%)", "idle_cpu_pct_median"))
md.append(row("Idle RAM median (MiB)", "idle_ram_mib_median"))
md.append(row("Idle process count median", "idle_procs_median"))
md.append(row("Max concurrent pairs", "max_concurrent_pairs"))
md.append(row("Exhaustion trigger", "exhaustion_trigger"))
md.append("")
with open(os.path.join(rd, "report.md"), "w") as f:
    f.write("\n".join(md))
print("\n".join(md))
PY
