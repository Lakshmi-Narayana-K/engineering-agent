#!/usr/bin/env node
/**
 * A deliberately inert MCP server used to answer one question:
 * does Cursor's `ask` session mode expose MCP tools, or suppress them?
 *
 * That question decides the entire security model for attaching RDS, CloudWatch
 * and Rapid7. V0's read-only guarantee rests on `ask` mode removing the
 * file-write and shell tools; MCP tools are a *different* tool class, and
 * assuming they inherit the same restriction would be exactly the kind of
 * untested assumption that causes an incident.
 *
 * It exposes a single `ping` tool that touches nothing and returns a sentinel.
 * If the sentinel comes back through the agent, MCP tools are live in `ask`
 * mode and must be constrained explicitly via `.cursor/cli.json` permissions.
 */
import { createInterface } from "node:readline";

const SENTINEL = "NKB_MCP_REACHABLE_IN_ASK_MODE";
const PROTOCOL_VERSION = "2024-11-05";

const rl = createInterface({ input: process.stdin });

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function reply(id, result) {
  if (id === undefined || id === null) return;
  send({ jsonrpc: "2.0", id, result });
}

const TOOLS = [
  {
    name: "ping",
    description:
      "Health probe. Takes no arguments, touches no external system, and returns a fixed sentinel string.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
];

const HANDLERS = {
  initialize: (id) =>
    reply(id, {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { tools: {} },
      serverInfo: { name: "nkb-probe", version: "1.0.0" },
    }),
  "tools/list": (id) => reply(id, { tools: TOOLS }),
  "tools/call": (id, params) => {
    const called = params?.name;
    if (called !== "ping") {
      reply(id, {
        content: [{ type: "text", text: `unknown tool: ${called}` }],
        isError: true,
      });
      return;
    }
    process.stderr.write(`[nkb-probe] ping invoked at ${new Date().toISOString()}\n`);
    reply(id, { content: [{ type: "text", text: SENTINEL }] });
  },
  "notifications/initialized": () => {},
  "resources/list": (id) => reply(id, { resources: [] }),
  "prompts/list": (id) => reply(id, { prompts: [] }),
};

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let msg;
  try {
    msg = JSON.parse(trimmed);
  } catch {
    return;
  }
  const handler = HANDLERS[msg.method];
  if (handler) {
    handler(msg.id, msg.params);
  } else if (msg.id !== undefined && msg.id !== null) {
    send({
      jsonrpc: "2.0",
      id: msg.id,
      error: { code: -32601, message: `method not found: ${msg.method}` },
    });
  }
});
