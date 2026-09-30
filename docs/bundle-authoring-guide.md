# Bundle Authoring Guide (Lab Authors)

DoD §15: *"Documentation updated: bundle-image authoring guide for Lab Authors,
including Compose local validation workflow."* This is that guide. It covers
adding a **new attacker tool bundle** end-to-end: image → CI → orchestrator →
lab-config → local Compose validation → production provisioning. Read
`docs/phase1/image-optimization.md` first for the *why*; this doc is the *how*.

## 0. Ground rules (violating any of these fails review)

| Rule | Source | Enforcement |
|---|---|---|
| Never `FROM kalilinux/kali-rolling` in the final stage; extract tools from a **throwaway** Kali stage | FR-01/FR-03, §3 root cause | code review + size gate (`ci/smoke.sh` step 1) |
| Final stage must be `FROM ${PLATFORM_BASE}` (the shared base, FR-16) | FR-16 marginal-disk ≤50 MB | `docker system df -v` delta (gate G4) |
| No apt metapackages (`*-tools`, `default-*`, `kali-tools-*`); enumerate exact packages | §3 root cause | review |
| `apt-get update && install` and `rm -rf /var/lib/apt/lists/*` in the SAME RUN layer | FR-01 build hygiene | review |
| Runtime user stays `lab` (non-root), never `--privileged` | NFR-03 | `ci/smoke.sh` step 5 |
| Nothing auto-starts except tini+ttyd — no daemons, no frameworks resident at idle | FR-18 | `ci/smoke.sh` step 3 (`docker top`) |
| SSH only via the per-lab opt-in (§5 below) | FR-18 | `ci/smoke.sh` step 13 + tests |
| Every new image gets a tool smoke test (`--version`) added to `ci/smoke.sh` step 2 | FR-04 publish integrity | CI blocks publish |

## 1. Create the bundle image

Copy the closest existing bundle as a template (`images/bundles/web-exploitation/Dockerfile`).
Structure that must survive copy-paste:

```dockerfile
# ---- throwaway tools stage: Kali by DIGEST PIN only, never in final image ----
FROM ${KALI_BASE} AS tools
RUN <extract exactly the files your tools need into /payload/>   # see existing bundles

# ---- final stage: shared base (FR-16) ----
FROM ${PLATFORM_BASE}
USER root
COPY --from=tools /payload/ /
RUN apt-get update && apt-get install -y --no-install-recommends <runtime deps only> \
 && rm -rf /var/lib/apt/lists/* && apt-get clean
COPY images/shared/entrypoint.sh    /usr/local/bin/entrypoint.sh
COPY images/shared/ssh-briefing.sh  /usr/local/bin/ssh-briefing.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/ssh-briefing.sh
HEALTHCHECK --interval=2s --timeout=2s --start-period=3s --retries=20 \
  CMD nc -z 127.0.0.1 "${TTYD_PORT:-7681}" || exit 1
USER lab
WORKDIR /home/lab
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

Rules for the tools stage:
- Copy **files, not package installs**, out of Kali (`cp -a` the tool tree + its
  `/usr/lib`/`/usr/share` data dirs). Note runtime libs (python3/ruby/perl) get
  reinstalled on the slim side — that's cheaper than dragging Kali's libc stack.
- Wordlists: curated subset only (see password-attacks' seclists pattern). The
  legacy 1.5 GB `wordlists` meta is banned.
- Heavy frameworks (metasploit): pre-install, document the lazy-start command in
  the bundle header comment, NEVER start it.

Register the name in three places (all are lists keyed by bundle name):
1. `images/build.sh` — the `all` target list + a `case` arm if needed;
2. `.github/workflows/images.yml` — publish loop `for i in ...`;
3. `orchestrator/api.js` — `KNOWN_BUNDLES`.

Add a placeholder digest line to `images/digests.env`
(`<BUNDLE>_DIGEST="sha256:000…"` — provision.sh's placeholder fallback makes
local dev work until CI publishes the real one) and a `tool_smoke` line to
`ci/smoke.sh` step 2 listing every shipped tool.

## 2. Add the lab-config entry

Create/extend `lab-configs/<bundle>.yaml` using the schema in
`lab-configs/sample-lab.yaml`. Every lab MUST declare:
- `needs_msfcore` + `lazy_start_ok` (FR-18 Phase-0 assumption check),
- `msf_start_deadline_s` if the lab can lazily invoke msfconsole,
- `ssh_enabled` (§5; default `false`).

## 3. Build & validate locally with Compose (FR-17 workflow)

No registry access needed — everything below runs against local tags.

```bash
# 3.1 build the shared base first, then your bundle (+ target if untouched)
./images/build.sh base
./images/build.sh <your-bundle>

# 3.2 one-shot static+dynamic gate run (needs a Docker daemon)
./ci/smoke.sh            # BUNDLE list comes from ci/smoke.sh; add yours there too

# 3.3 reproduce a session pair locally — SAME limits, SAME images as prod
set -a; . orchestrator/limits.env; set +a
BUNDLE=<your-bundle> docker compose --env-file orchestrator/limits.env \
  -f compose/session.yml up -d

# 3.4 prove the essentials yourself before opening the PR:
docker top sess-attacker                       # <= 3 procs, no sshd/msf (FR-18)
docker inspect -f '{{.Config.User}}' sess-attacker   # -> "lab" (NFR-03)
docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.PidsLimit}}' sess-attacker
curl -s http://127.0.0.1:7681/ | head -1       # ttyd terminal answers
docker exec sess-attacker <tool> --version     # each shipped tool runs
docker compose -f compose/session.yml down

# 3.5 marginal-disk sanity (FR-16): two sessions of DIFFERENT bundles should
# share the base layers — the delta after the second pull must stay small.
docker system df -v | grep -E 'platform/(base|<your-bundle>)'
```

Parity contract: `compose/session.yml` is the reference for the production
`docker run` flags — if you change limits or flags, both files move together and
`ci/smoke.sh` steps 6–7 fail loudly on drift (NFR-08). See
`compose/orchestrator-flags.md` for the key-by-key mapping.

## 4. Provision through the orchestrator (pre-merge smoke)

```bash
REGISTRY=local VERSION=phase1 KEEP_RUNNING=1 \
  ./orchestrator/provision.sh <your-bundle> mytest-1
curl -s localhost:8080/sessions/mytest-1          # if api.js running
curl -s -X DELETE localhost:8080/sessions/mytest-1
```

provision.sh needs **no changes** for a new bundle beyond the digests.env entry
(NFR-06: bundle selection is pure configuration).

## 5. SSH opt-in (only when genuinely required)

Default posture: no sshd. If a lab truly needs inbound SSH (e.g. pivoting):
1. set `ssh_enabled: true` in the lab's `lab-configs/<bundle>.yaml` entry,
   with a justification comment, AND
2. get Platform Engineering sign-off (it costs one resident process + attack
   surface; reviewers must confirm the ≤3 idle-process budget still holds), OR
   the request goes to the PRD open-questions table instead.
Nothing else to wire: provision.sh resolves the flag, the entrypoint starts
sshd via `ssh-briefing.sh`, and the reaper treats established :22 connections
as activity so attached learners aren't reaped. Per-session override for tests:
`LAB_SSH_ENABLED=1 ./orchestrator/provision.sh …` or
`POST /sessions {"bundle":…, "id":…, "ssh": true}`.

## 6. Publish flow recap (what CI does after your PR merges)

build (BuildKit cache) → `ci/smoke.sh` gates → push immutable `${{ github.sha }}`
tag to GHCR → write real digest into `images/digests.env` (maintainer commit) →
FR-14 prune keeps runner/host disk bounded. Sessions pull by digest only — your
bundle never builds on a session host (FR-04/FR-05).

## Checklist for the PR

- [ ] Dockerfile follows §1 skeleton (throwaway tools stage, PLATFORM_BASE final)
- [ ] names registered: build.sh / images.yml / api.js KNOWN_BUNDLES / digests.env placeholder
- [ ] `ci/smoke.sh`: tool_smoke line added; bundle in BUNDLES list
- [ ] `lab-configs/<bundle>.yaml` with all labs declaring lazy_start_ok + ssh_enabled
- [ ] §3 Compose validation run locally, outputs pasted in the PR description
- [ ] `docker top` ≤3 at idle; non-root; healthcheck passes
- [ ] `node --test orchestrator/test/` green (no regressions in provisioning path)
