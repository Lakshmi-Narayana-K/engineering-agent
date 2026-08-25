#!/usr/bin/env node
/**
 * Runs the ACP permission cases in policy-cases.json against the live policy
 * boundary and reports each verdict against its expectation.
 *
 * This is the gate referenced by the migration plan: responsibilities move out
 * to upstream components (sandbox, ToolHive, IAM, a read-only database role)
 * one at a time, and nothing custom gets deleted until this suite still
 * produces the same verdicts without it. Recording the baseline is therefore
 * the point, not a side effect.
 *
 *   node tests/security/run-policy-tests.mjs [--json <path>]
 *
 * Exit code is the number of mismatches, so CI fails on the first regression.
 */

import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..");
const CASES = path.join(HERE, "policy-cases.json");
const SHIM = path.join(ROOT, "runtime", "cursor", "cursor-acp-shim.mjs");

const jsonFlag = process.argv.indexOf("--json");
const jsonOut = jsonFlag === -1 ? null : process.argv[jsonFlag + 1];

const resultsPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "nkb-sec-")), "results.json");

const child = spawn(process.execPath, [SHIM, "acp"], {
  cwd: ROOT,
  stdio: ["pipe", "pipe", "inherit"],
  env: {
    ...process.env,
    // Puts the fake agent ahead of the real Cursor CLI for this process only.
    PATH: `${path.join(HERE, "fake-agent")}${path.delimiter}${process.env.PATH}`,
    NKB_POLICY_CASES: CASES,
    NKB_POLICY_RESULTS: resultsPath,
  },
});

// The shim relays anything it does not handle; discard it so the pipe cannot fill.
child.stdout.resume();

child.on("exit", () => {
  if (!fs.existsSync(resultsPath)) {
    console.error("no results were produced - the shim exited before answering");
    process.exit(1);
  }

  const results = JSON.parse(fs.readFileSync(resultsPath, "utf8"));
  const width = Math.max(...results.map((r) => r.name.length));
  const mismatches = [];

  console.log(`\nACP permission boundary - ${results.length} cases\n`);
  for (const r of results) {
    const ok = r.actual === r.expect;
    if (!ok) mismatches.push(r);
    const mark = ok ? "pass" : "FAIL";
    const verdict = ok ? r.actual : `${r.actual} (expected ${r.expect})`;
    console.log(`  ${mark}  ${r.name.padEnd(width)}  ${verdict}`);
  }

  const owners = results.reduce((acc, r) => {
    acc[r.owner] = (acc[r.owner] ?? 0) + 1;
    return acc;
  }, {});

  console.log(`\n  ${results.length - mismatches.length}/${results.length} as expected`);
  console.log("\nPost-migration owner of each decision:");
  for (const [owner, n] of Object.entries(owners).sort((a, b) => b[1] - a[1])) {
    console.log(`  ${String(n).padStart(3)}  ${owner}`);
  }

  if (mismatches.length) {
    console.log("\nMismatches:");
    for (const m of mismatches) console.log(`  ${m.name}: got ${m.actual}, expected ${m.expect}`);
  }

  if (jsonOut) {
    fs.mkdirSync(path.dirname(jsonOut), { recursive: true });
    fs.writeFileSync(
      jsonOut,
      JSON.stringify(
        {
          capturedAt: new Date().toISOString(),
          total: results.length,
          matched: results.length - mismatches.length,
          results,
        },
        null,
        2,
      ) + "\n",
    );
    console.log(`\nwrote ${jsonOut}`);
  }

  console.log("");
  process.exit(mismatches.length);
});
