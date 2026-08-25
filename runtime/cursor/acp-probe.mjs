#!/usr/bin/env node
/**
 * Raw ACP probe for `agent acp`.
 *
 * Runs the ACP handshake directly, without OpenHands in the path, so that a
 * failure here can be attributed to Cursor rather than to Agent Server.
 * Records every inbound method name; the `cursor/*` extension methods are the
 * ones Agent Server has no handler for, and the blocking ones among them
 * (cursor/ask_question, cursor/create_plan) would stall a turn.
 *
 * Usage: node acp-probe.mjs [--cwd <dir>] [--mode <agent|plan|ask>] [--prompt <text>]
 */
import { spawn } from "node:child_process";
import readline from "node:readline";
import process from "node:process";

const BLOCKING_EXTENSIONS = new Set(["cursor/ask_question", "cursor/create_plan"]);
const TURN_TIMEOUT_MS = 180_000;

function parseArgs(argv) {
  const args = { cwd: process.cwd(), mode: "ask", prompt: "Respond with exactly: CURSOR_ACP_CONNECTED" };
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i]?.replace(/^--/, "");
    if (key && key in args && argv[i + 1] !== undefined) args[key] = argv[i + 1];
  }
  return args;
}

const { cwd, mode, prompt } = parseArgs(process.argv.slice(2));

const observedMethods = new Map();
// NKB_ACP_COMMAND lets the probe run through the shim instead of `agent acp`,
// so the same test exercises both integration paths. It is a JSON argv array
// because workspace paths here contain spaces.
const [command, ...commandArgs] = JSON.parse(process.env.NKB_ACP_COMMAND ?? '["agent","acp"]');
const agent = spawn(command, commandArgs, { cwd, stdio: ["pipe", "pipe", "pipe"] });

let nextId = 1;
const pending = new Map();
let streamed = "";

function send(method, params) {
  const id = nextId++;
  agent.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

function respond(id, result) {
  agent.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

function note(method) {
  observedMethods.set(method, (observedMethods.get(method) ?? 0) + 1);
}

readline.createInterface({ input: agent.stdout }).on("line", (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }

  if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
    const waiter = pending.get(msg.id);
    if (!waiter) return;
    pending.delete(msg.id);
    msg.error ? waiter.reject(msg.error) : waiter.resolve(msg.result);
    return;
  }

  if (!msg.method) return;
  note(msg.method);

  if (msg.method === "session/update") {
    const update = msg.params?.update;
    if (update?.sessionUpdate) note(`  session/update:${update.sessionUpdate}`);
    if (update?.sessionUpdate === "agent_message_chunk" && update.content?.text) {
      streamed += update.content.text;
      process.stderr.write(update.content.text);
    }
    return;
  }

  if (msg.method === "session/request_permission") {
    respond(msg.id, { outcome: { outcome: "selected", optionId: "allow-once" } });
    return;
  }

  // Anything else addressed to us with an id is a blocking request. Answering
  // keeps the turn alive; the point of the probe is to learn whether it happens.
  if (msg.id !== undefined) {
    if (msg.method === "cursor/ask_question") {
      respond(msg.id, { outcome: { outcome: "skipped", reason: "probe runs unattended" } });
    } else if (msg.method === "cursor/create_plan") {
      respond(msg.id, { outcome: { outcome: "accepted" } });
    } else {
      respond(msg.id, {});
    }
  }
});

readline.createInterface({ input: agent.stderr }).on("line", (line) => {
  if (line.trim()) process.stderr.write(`[stderr] ${line}\n`);
});

function report(status, detail) {
  const extensions = [...observedMethods.keys()].filter((m) => m.startsWith("cursor/"));
  console.log(
    "\n" +
      JSON.stringify(
        {
          status,
          detail,
          cwd,
          mode,
          streamedText: streamed.trim(),
          containsSentinel: streamed.includes("CURSOR_ACP_CONNECTED"),
          observedMethods: Object.fromEntries(observedMethods),
          cursorExtensionsSeen: extensions,
          blockingExtensionsSeen: extensions.filter((m) => BLOCKING_EXTENSIONS.has(m)),
        },
        null,
        2,
      ),
  );
}

const timer = setTimeout(() => {
  report("TIMEOUT", `no turn completion within ${TURN_TIMEOUT_MS}ms`);
  agent.kill("SIGKILL");
  process.exit(2);
}, TURN_TIMEOUT_MS);

try {
  const init = await send("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    clientInfo: { name: "nkb-acp-probe", version: "0.1.0" },
  });
  console.log("initialize ->", JSON.stringify(init));

  try {
    await send("authenticate", { methodId: "cursor_login" });
    console.log("authenticate -> ok");
  } catch (err) {
    // Expected when the CLI is already signed in via `agent login`.
    console.log("authenticate -> skipped:", err?.message ?? JSON.stringify(err));
  }

  const session = await send("session/new", { cwd, mcpServers: [] });
  console.log("session/new ->", JSON.stringify(session));

  if (mode) {
    try {
      await send("session/set_mode", { sessionId: session.sessionId, modeId: mode });
      console.log(`session/set_mode -> ${mode}`);
    } catch (err) {
      console.log("session/set_mode -> unsupported:", err?.message ?? JSON.stringify(err));
    }
  }

  const result = await send("session/prompt", {
    sessionId: session.sessionId,
    prompt: [{ type: "text", text: prompt }],
  });

  clearTimeout(timer);
  report("OK", `stopReason=${result.stopReason}`);
  agent.stdin.end();
  agent.kill();
  process.exit(0);
} catch (err) {
  clearTimeout(timer);
  report("ERROR", err?.message ?? JSON.stringify(err));
  agent.stdin.end();
  agent.kill();
  process.exit(1);
}
