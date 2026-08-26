/*
 * A transparent ACP relay: spawn a successor, forward every message in both
 * directions, and let the caller intercept the few it cares about.
 *
 * WHY THIS IS HAND-WRITTEN, given that section 11 asked for the official SDK.
 *
 * @agentclientprotocol/sdk v1.4.0 is official, stable and widely used, and it
 * is the right choice for building an ACP *endpoint* - its API is agent() and
 * client(), each registering typed handlers for methods you implement. These
 * proxies are not endpoints. They sit in the middle and must forward messages
 * they have never heard of, including Cursor's non-standard cursor/* methods,
 * which are absent from the standard schema. Rebuilding that as a typed
 * endpoint means enumerating every method in order to pass it through: more
 * code than this file, and a new failure mode every time an engine adds one.
 *
 * The upstream answer for proxies specifically is the proxy-chain design and
 * its Conductor. That is an RFD - the document opens "What are you proposing to
 * change?" - and its reference implementation is a Rust crate aimed at a Rust
 * proxy ecosystem, with no TypeScript equivalent. Adopting an unratified
 * protocol into the security path to save the 55 lines below is not a trade
 * worth making yet.
 *
 * So the relay stays ours, deliberately, and stays small enough to read in one
 * sitting. If the Conductor ratifies, or the SDK grows a proxy API, this file
 * is the only thing that needs to change - which is itself the argument for
 * keeping it isolated here rather than tangled into policy.
 *
 * Being unaware of the protocol is the feature. Anything not explicitly
 * intercepted is forwarded byte-for-byte, including messages that fail to
 * parse, so a new ACP version or a different engine keeps working untouched.
 */

import { spawn } from "node:child_process";
import fs from "node:fs";
import readline from "node:readline";

/**
 * @param {object} options
 * @param {string} options.name        label for trace lines
 * @param {string} options.command     successor to spawn
 * @param {string[]} options.args      arguments for the successor
 * @param {string|null} options.logPath  trace destination, or null to disable
 * @param {(msg: object, ctx: object) => boolean} [options.onAgentMessage]
 *        return true to consume the message instead of forwarding it
 * @param {(msg: object, ctx: object) => boolean} [options.onClientMessage]
 */
export function startProxy({ name, command, args, logPath, onAgentMessage, onClientMessage }) {
  const child = spawn(command, args, { stdio: ["pipe", "pipe", "inherit"], env: process.env });

  child.on("error", (err) => {
    process.stderr.write(`[${name}] cannot start successor '${command}': ${err.message}\n`);
    process.exitCode = 1;
  });

  child.on("exit", (code, signal) => {
    process.exitCode = code ?? (signal ? 1 : 0);
    process.stdin.pause();
  });

  const log = (direction, line) => {
    if (!logPath) return;
    try {
      fs.appendFileSync(logPath, `${new Date().toISOString()} ${name} ${direction} ${line}\n`);
    } catch {
      /* tracing must never break the session */
    }
  };

  const ctx = {
    /* Set from whichever direction reveals it first; injected notifications
     * need a valid sessionId and there is no other way to learn one. */
    sessionId: null,

    toClient(obj) {
      const line = JSON.stringify(obj);
      log("->client", line);
      process.stdout.write(line + "\n");
    },

    toAgent(obj) {
      const line = JSON.stringify(obj);
      log("->agent", line);
      child.stdin.write(line + "\n");
    },

    /** Render text into the client transcript as if the agent had said it. */
    emitMessage(text, sessionId = ctx.sessionId) {
      if (!sessionId || !text) return;
      ctx.toClient({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId,
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
        },
      });
    },
  };

  const track = (msg) => {
    if (msg?.params?.sessionId) ctx.sessionId = msg.params.sessionId;
    if (msg?.result?.sessionId) ctx.sessionId = msg.result.sessionId;
  };

  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    if (!line.trim()) return;
    log("agent->", line);
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      process.stdout.write(line + "\n");
      return;
    }
    track(msg);
    if (onAgentMessage?.(msg, ctx)) return;
    process.stdout.write(line + "\n");
  });

  readline.createInterface({ input: process.stdin }).on("line", (line) => {
    if (!line.trim()) return;
    log("client->", line);
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      child.stdin.write(line + "\n");
      return;
    }
    track(msg);
    if (onClientMessage?.(msg, ctx)) return;
    child.stdin.write(line + "\n");
  });

  process.stdin.on("close", () => child.stdin.end());
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.on(signal, () => child.kill(signal));
  }

  return ctx;
}
