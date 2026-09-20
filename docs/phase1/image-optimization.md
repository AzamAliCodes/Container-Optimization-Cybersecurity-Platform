# Phase 1 — Image Optimization (FR-01/02/03/04/07/16/17/18)

Design record for the optimised image set. One paragraph per decision; the files
themselves are the source of truth (`images/`, `compose/`, `ci/`).

## Shared base layer (FR-16)

`platform/base` (`images/base/Dockerfile`) is derived from **digest-pinned
`debian:bookworm-slim`** and carries everything common to every session image:
tini (PID 1), ttyd (learner web terminal), `nc` for health probes, the non-root
`lab` user, and the shared entrypoint. Every attacker bundle **and** the target
image derive from it, so on any host the first pull lays these layers down once
and sessions N..M reuse them via OverlayFS copy-on-write — this is what makes
the ≤ 50 MB marginal-disk KPI (PRD §5 / FR-16) structurally achievable.

## Multi-stage pattern (FR-01 + FR-03)

Kali packages can only be *installed* inside the Kali lineage, so each bundle
installs its curated tool set in a throwaway `FROM ${KALI_BASE} AS tools` stage
and `COPY --from=tools` extracts only the tool trees onto `platform/base`. No
apt index/cache, no compilers, and no Kali package-manager state ever bakes into
a published layer. Runtime library deps (python3/ruby/libpcap/…) are installed
on the base side with `--no-install-recommends`, lists removed in the same RUN.

| Bundle | Tools shipped (exact FR-03 split) | Deliberately NOT shipped |
|---|---|---|
| `web-exploitation` | sqlmap, hydra, whatweb, 3 curated wordlists | metasploit, nmap sweep stack, 1.5 GB `wordlists` meta |
| `network-recon` | nmap (+ncat/nping), metasploit-framework (**lazy-started**) | sqlmap/hydra/whatweb, hashcat/john |
| `password-attacks` | hydra, john, hashcat, 3 curated wordlists | everything framework-shaped |
| `target` | php-cli + sqlite ext serving the SQLi app via `php -S` | apache2+mod_php, build-essential, vim |

## Digest pinning (FR-02)

`images/digests.env` is the single source of truth: `BASE_DEBIAN` and
`KALI_BASE` pinned by `@sha256:` digest, plus pinned versions **and SHA-256
checksums** for the ttyd/tini release binaries (fetched in a build-only stage,
verified with `sha256sum -c`, copied out). `images/build.sh` sources the file
and passes every value as `--build-arg`; Dockerfile ARG defaults mirror it so a
bare `docker build` still works, but CI always goes through `build.sh`.
Refresh cadence: monthly rebuild against these pins; off-cycle only for critical
CVEs (`docker buildx imagetools inspect <repo>:<tag>` → update digest + comment).

## Minimal idle process set (FR-18)

`images/shared/entrypoint.sh` starts **only**:

- attacker: `tini → ttyd` (2 resident processes; the shell tier exists only
  while a client is attached)
- target: `tini → ttyd (-C pass-through) + php -S` app server

Explicitly never auto-started: **sshd** (opt-in per lab via `LAB_SSH_ENABLED=1`,
handled by `images/shared/ssh-briefing.sh`) and **msfconsole** (pre-installed in
network-recon, launched lazily by the learner). This removes both legacy
resident hogs identified in the Phase 0 baseline.

### Per-lab SSH opt-in — end-to-end wiring (FR-18)

The flag is a declared, validated path, not an ad-hoc env var. Resolution
order (first hit wins, implemented in `orchestrator/provision.sh`):

1. **explicit env / API body** — `POST /sessions {bundle, id, ssh: true}`
   forwards `LAB_SSH_ENABLED=1`; non-boolean `ssh` → HTTP 400;
2. **lab-config** — `lab-configs/<bundle>.yaml` entries carry
   `ssh_enabled: true|false` (schema documented in `lab-configs/sample-lab.yaml`;
   `network-recon.yaml`'s `pivot-002` is the worked example of an opted-in lab);
3. **default `0`** — no declaration anywhere ⇒ sshd never starts.

Mechanics: provision.sh injects `--env LAB_SSH_ENABLED=<0|1>` into the
**attacker container only**; `images/shared/entrypoint.sh` double-guards on the
var before invoking `ssh-briefing.sh` (which itself re-checks), so a container
without the flag cannot start sshd even if the orchestrator misbehaves. The
reaper's idle detector adds an SSH liveness signal (`detect_idle.sh`
`ssh_attached()`): established connections on :22 reset the low-sample counter,
so pivoting labs are never idle-reaped while attached.

Gates & tests: `ci/smoke.sh` step 13 statically asserts the whole chain
(schema → provision → api → entrypoint guard); `node --test orchestrator/test/`
covers runtime behaviour (5 provisioning-path cases incl. precedence +
attacker-only scoping, 3 API validation cases). Opted-in sessions cost one
extra resident process (sshd) — still within the ≤3 KPI at attacker tier when
no terminal client is attached; labs that need SSH must be reviewed for this
trade-off before merge.

## Health checks (FR-07)

Every image declares `HEALTHCHECK … nc -z 127.0.0.1 <port>`: attacker/bundles on
ttyd port 7681, target on the app port 8080. Cold-start = "healthcheck pass",
which the Phase 0 harness had to approximate with external probes (legacy images
had none). Note: ttyd runs `-W` so the port answers at boot without a client —
the probe measures provision→ready, not client attach.

## Local environment (FR-17)

`compose/session.yml` reproduces one session pair (attacker bundle + target) on
an isolated per-session bridge network, with the **LIMIT-PARITY-TABLE** ceilings
(attacker 512m/768m/1.0cpu/pids100, target 256m/384m/0.5cpu/pids50) recorded as
a comment block that `ci/smoke.sh` asserts against `docker inspect` (NFR-08).
Compose never builds images (pre-build via `images/build.sh`, publish via CI —
FR-04). `compose/orchestrator-flags.md` maps each compose key to the production
`docker run` flag.

## CI publish gate (FR-04)

`.github/workflows/images.yml`: BuildKit build of base+target+3 bundles →
`ci/smoke.sh` gates (size ≤ 800/400 MB, per-tool `--version` smoke, FR-18 idle
process count via `docker top`, FR-07 healthy, NFR-03 non-root, NFR-08 limit
parity) → push to GHCR with the immutable `${{ github.sha }}` tag **only if all
gates pass**. PRs get build+gate without publish.

## Verification status

Static verification completed in this sandbox (no Docker daemon available):
`bash -n` on all scripts (fixed two unbalanced-quote syntax errors in
`ci/smoke.sh`'s size gates), YAML parse of `compose/session.yml`, and existence
checks for every Dockerfile `COPY` source. The dynamic exit criteria — measured
image sizes vs §5 targets, `docker top` idle counts, `docker compose up` — must
run on a Docker-capable host:

```bash
./images/build.sh all && ./ci/smoke.sh   # all four Phase 1 exit criteria in one run
```

Expected outcomes based on design: bundles well under 800 MB (largest layer is
metasploit's tree), target ≈ base + php (~200 MiB), attacker idle procs = 2–3,
no sshd/msf at idle.
