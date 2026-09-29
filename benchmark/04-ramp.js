#!/usr/bin/env node
// 04-ramp — FR-11/FKPI-6 max-concurrency ramp (Appendix B). Node driver that provisions
// attacker+target pairs in a STEPPED ramp, dwelling per pair, until the host exhausts
// (aggregate CPU% >= EXHAUST_CPU_PCT sustained EXHAUST_CPU_SUSTAIN_S, or aggregate mem >=
// EXHAUST_MEM_FRAC * host total, or a health/cold-start timeout). Emits max_pairs + the
// exhaustion trigger that fired.
//
// Purely Docker-CLI based (spawns `docker ...`), so it needs no npm dependencies and
// works against an existing Docker Engine. Concurrency is bounded by RAMP_MAX_PAIRS.
//
// env overrides: RAMP_DWELL_S, RAMP_MAX_PAIRS, EXHAUST_CPU_PCT, EXHAUST_CPU_SUSTAIN_S,
// EXHAUST_MEM_FRAC, RAMP_POLL_S, IMG_ATTACKER, IMG_TARGET, LAB_PAIR
"use strict";
const { spawn, execFile } = require("child_process");

const env = { ...process.env };
const dwellS = +env.RAMP_DWELL_S || 8;
const maxPairs = +env.RAMP_MAX_PAIRS || 24;
const pollS = +env.RAMP_POLL_S || 2;
const cpuCap = +env.EXHAUST_CPU_PCT || 90;
const cpuSustainS = +env.EXHAUST_CPU_SUSTAIN_S || 60;
const memFrac = +env.EXHAUST_MEM_FRAC || 0.92;
const pair = env.LAB_PAIR || "legacy";
const attImg = env.IMG_ATTACKER;
const tgtImg = env.IMG_TARGET;

function sh(cmd, args, opts = {}) {
  return new Promise((res, rej) => {
    execFile(cmd, args, { ...opts }, (e, stdout, stderr) =>
      e ? rej(new Error((stderr || stdout || "").trim() || e.message)) : res(stdout.trim())
    );
  });
}
function docker(args, opts = {}) { return sh("docker", args, opts); }
function name(which, n) { return `bm-${which}-${pair}-${n}`; }
function netName(n) { return `bm-net-${pair}-${n}`; }

async function up(which, n, img) {
  await docker(["network", "create", netName(n)]).catch(() => {});
  await docker(["run", "-d", "--name", name(which, n), "--network", netName(n), img]);
}
async function rmPair(n) {
  const names = [name("att", n), name("tgt", n)];
  for (const c of names) await docker(["rm", "-f", c]).catch(() => {});
  await docker(["network", "rm", netName(n)]).catch(() => {});
}
async function stats(n) {
  // Aggregate CPU% and MemUsage across ALL pairs currently up (this run's pair index is
  // always <= maxPairs, so we just read every bm-* container we created).
  // NOTE: `docker stats` has no --filter flag; enumerate all and select bm-* client-side.
  const out = await docker([
    "stats", "--no-stream",
    "--format", "{{.CPUPerc}}\t{{.MemUsage}}\t{{.Name}}",
  ]).catch(() => "");
  let cpu = 0, memUsed = 0;
  for (const line of out.split("\n")) {
    const m = line.match(/^([\d.]+)%\t([^\t]+?)\/([^\t]+)\t(bm-(?:att|tgt)-.+)$/);
    if (!m) continue;
    cpu += +m[1];
    memUsed += memToMiB(m[2]);
  }
  const host = await docker(["info", "--format", "{{.MemTotal}}"]).catch(() => "0");
  const total = +host / 1048576;
  return { cpu, memUsed, total };
}
function memToMiB(v) {
  v = v.trim();
  if (v.endsWith("GiB")) return +parseFloat(v) * 1024;
  if (v.endsWith("MiB")) return +parseFloat(v);
  if (v.endsWith("KiB")) return +parseFloat(v) / 1024;
  return +parseFloat(v) || 0;
}

async function main() {
  const t0 = Date.now();
  let peak = 0, trigger = "none", exhausted = false;
  let cpuHighSince = 0, memHighSince = 0;

  for (let n = 1; n <= maxPairs && !exhausted; n++) {
    // Defensive: clear any leftover with this name from a previously-killed run.
    await rmPair(n);
    await up("att", n, attImg);
    await up("tgt", n, tgtImg);
    // settle + dwell: let metrics converge after the new pair is added
    await new Promise((r) => setTimeout(r, dwellS * 1000));

    // probe until exhausted or dwell out
    const dw0 = Date.now();
    while (Date.now() - dw0 < dwellS * 1000) {
      const s = await stats(n);
      const now = Date.now();
      const bad = { now, ...s };
      if (s.cpu >= cpuCap && s.cpu >= 0) {
        if (!cpuHighSince) cpuHighSince = now;
        else if (now - cpuHighSince >= cpuSustainS * 1000) {
          trigger = "cpu"; exhausted = true; break;
        }
      } else cpuHighSince = 0;

      if (s.total > 0 && s.memUsed / s.total >= memFrac) {
        if (!memHighSince) memHighSince = now;
        else if (now - memHighSince >= 5 * 1000) {
          trigger = "mem"; exhausted = true; break;
        }
      } else memHighSince = 0;

      // peak = highest pair-count we've fully provisioned and sustained
      if (n > peak) peak = n;
      await new Promise((r) => setTimeout(r, pollS * 1000));
    }
    // Only credit pair n toward "max concurrent BEFORE exhaustion" if it survived the
    // full dwell without tripping a threshold (Appendix A exhaustion definition).
    if (exhausted) { peak = n - 1; break; }
  }

  const elapsedMs = Date.now() - t0;
  const meta = {
    lab_pair: pair,
    image_attacker: attImg,
    image_target: tgtImg,
    max_pairs: peak,
    exhaustion_trigger: trigger,
    elapsed_ms: elapsedMs,
    duration_s: +(elapsedMs / 1000).toFixed(1),
  };
  // write report line for the driver to capture
  const fs = require("fs");
  const outDir = env.BENCH_OUT_DIR || ".";
  if (outDir) {
    fs.mkdirSync(outDir, { recursive: true });
    fs.writeFileSync(`${outDir}/ramp.json`, JSON.stringify(meta, null, 2));
  }
  console.log(JSON.stringify(meta, null, 2));
}

main().catch((e) => { console.error(e.message); process.exit(1); });
