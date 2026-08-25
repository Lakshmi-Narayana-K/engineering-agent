#!/usr/bin/env node
/**
 * A stub SQL tool that connects to no database.
 *
 * The gating in config/acp-permissions.json under mcp.sqlQuery is what would
 * stand between the agent and a production database, and it is worth more than
 * an assumption that it works. No MySQL database exists in the alpha account and
 * nothing there is network-reachable, so there is no way to exercise that gating
 * against a real server.
 *
 * This exposes the same shape a real SQL tool has -- one `run_query` tool taking
 * a `sql` string -- and echoes back what it was given. Whether a statement gets
 * this far is decided entirely by the shim, so the reply proves the decision.
 * Reaching a real database changes only which server is attached, not the gating.
 */
import { createInterface } from "node:readline";

const PROTOCOL_VERSION = "2024-11-05";

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function reply(id, result) {
  if (id === undefined || id === null) return;
  send({ jsonrpc: "2.0", id, result });
}

const TOOLS = [
  {
    name: "run_query",
    description:
      "Run a read-only SQL query. Takes a single `sql` string. This is a stub: it " +
      "executes nothing and returns a description of what it received.",
    inputSchema: {
      type: "object",
      properties: { sql: { type: "string", description: "The SQL statement to run." } },
      required: ["sql"],
      additionalProperties: false,
    },
  },
];

const HANDLERS = {
  initialize: (id) =>
    reply(id, {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { tools: {} },
      serverInfo: { name: "sql-probe", version: "1.0.0" },
    }),
  "tools/list": (id) => reply(id, { tools: TOOLS }),
  "tools/call": (id, params) => {
    if (params?.name !== "run_query") {
      reply(id, {
        content: [{ type: "text", text: `unknown tool: ${params?.name}` }],
        isError: true,
      });
      return;
    }
    const sql = String(params?.arguments?.sql ?? "");
    process.stderr.write(`[sql-probe] reached with: ${sql}\n`);
    reply(id, {
      content: [
        {
          type: "text",
          text:
            `NKB_SQL_PROBE_REACHED\nstatement: ${sql}\n` +
            "No database was contacted. Arriving here means the workspace policy " +
            "permitted this statement.",
        },
      ],
    });
  },
  "notifications/initialized": () => {},
  "resources/list": (id) => reply(id, { resources: [] }),
  "prompts/list": (id) => reply(id, { prompts: [] }),
};

createInterface({ input: process.stdin }).on("line", (line) => {
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
