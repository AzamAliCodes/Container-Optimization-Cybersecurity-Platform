# Measured before/after — legacy vs optimized, same host

Both image sets were built and run on **this host** (macOS, 8 vCPU, 8 GiB RAM,
Docker 29.8.0) on 2026-10-01. Identical protocol for both sides: one pair,
60 s settle, 8 samples at 8 s intervals, `docker stats --no-stream`.

- **Legacy** — `legacy-images/` reproduced exactly as the PRD describes:
  `kalilinux/kali-rolling` single-stage with metasploit-framework + nmap +
  sqlmap + hydra + openssh-server, apt cache baked in, root, no HEALTHCHECK,
  no resource limits; target is full `debian:bookworm` + apache2 + mod_php +
  build-essential, no HEALTHCHECK, no limits.
- **Optimized** — `platform/web-exploitation:phase1` + `platform/target:phase1`
  with `orchestrator/limits.env` quotas enforced (attacker 512m/1.0cpu/100
  pids, target 256m/0.5cpu/50 pids).

## Image size

| Image | Legacy (built & measured) | Optimized | Reduction |
|---|---|---|---|
| Attacker | **3650 MiB** | 342 MiB | **90.6%** |
| Target | **955 MiB** | 275 MiB | **71.2%** |

## Idle footprint (the per-session cost)

| | Attacker | Target | **Pair total** | Procs |
|---|---|---|---|---|
| Legacy | 401.5 MiB | 45.0 MiB | **446.5 MiB** | 15 (8 att + 7 tgt) |
| Optimized | 17.9 MiB | 27.6 MiB | **45.4 MiB** | 5 (2 att + 3 tgt) |
| | | | **89.8% ↓ (9.8×)** | **15 → 5** |

The attacker's resident footprint drops **22.4×** (401.5 → 17.9 MiB): the legacy
image holds a resident `msfconsole` (JRuby) and `sshd`, while the optimized
bundle starts neither until a lab actually needs them.

## Concurrency — the honest result

| | Max stable pairs on this 8 GiB host |
|---|---|
| Legacy | **37** |
| Optimized | **62** |
| Ratio | **1.7×** |

Legacy containers remained functional at the ceiling (`msfconsole` alive,
8 processes). Both sides were driven by the same loop; legacy's 38th attacker
stalled in `Created`.

### The ≥3× target is NOT met on this host

**9.8× less memory per pair yielded only 1.7× more sessions.** That gap is the
most important finding in this document, and it is not a measurement error.

The cause is that **legacy containers have no limits at all**, so macOS treats
their memory as reclaimable: the host compressed ~3.4 GB and kept running. The
optimized side runs under hard cgroup quotas. In other words, the legacy
baseline was never actually capped — it borrowed unbounded host headroom, and
macOS's compressor absorbed it rather than failing fast.

Consequences for how this must be reported:

- On a host with a **hard** memory ceiling (bare metal, a VM with a fixed
  balloon, or `--memory` applied to the legacy pair for comparison) the 9.8×
  per-pair advantage should translate into far more than 1.7×, because the
  legacy pair cannot borrow the compressor's slack.
- On **this** host the ratio is 1.7×, and that is the number to quote.
- The capacity model in `benchmark/model.py` projects 2.1× on worst-case
  *committed quota*. The measured 1.7× is close to that projection, which
  suggests the model is roughly right and the ≥3× ambition was optimistic.

Anyone re-running this should note the compressor behaviour is macOS-specific;
a Linux host with no overcommit will show a different (likely larger) ratio.

## Method / reproduction

```bash
# build the legacy baseline (Kali attacker is ~3.6 GB; expect a long build)
docker build -f legacy-images/target/Dockerfile   -t platform/target:legacy   .
docker build -f legacy-images/attacker/Dockerfile -t platform/attacker:legacy .

# identical idle protocol for either pair
docker run -d --name cm-att platform/attacker:legacy
docker run -d --name cm-tgt platform/target:legacy
sleep 60
for i in $(seq 1 8); do docker stats --no-stream cm-att cm-tgt; sleep 8; done
docker top cm-att | tail -n +2 | wc -l   # 8 legacy / 2 optimized

# optimized side, quotas enforced
set -a; . orchestrator/limits.env; set +a
docker run -d --name cm-att --memory=$ATTACKER_MEMORY --memory-swap=$ATTACKER_MEMORY_SWAP \
  --cpus=$ATTACKER_CPUS --pids-limit=$ATTACKER_PIDS_LIMIT platform/web-exploitation:phase1
docker run -d --name cm-tgt --memory=$TARGET_MEMORY --memory-swap=$TARGET_MEMORY_SWAP \
  --cpus=$TARGET_CPUS --pids-limit=$TARGET_PIDS_LIMIT platform/target:phase1

# concurrency ceiling
for i in $(seq 1 70); do
  docker run -d --name lx-a-$i platform/attacker:legacy  || break
  docker run -d --name lx-t-$i platform/target:legacy    || break
done
docker rm -f $(docker ps -aq)
```

Raw numbers for this run are in `docs/before-after-measurements.json`.
Earlier single-side measurements and the fabricated-data audit are in
`docs/audit-real-measurements.md`.