#!/usr/bin/env node
/*
 * NKB ACP permission proxy.
 *
 * The one security-critical component we still write ourselves. It owns
 * exactly three things, per section 12:
 *
 *   1. deciding session/request_permission
 *   2. auditing that decision
 *   3. failing closed when it cannot decide
 *
 * Everything it used to own has moved to something that enforces it properly:
 * MCP tool admission to ToolHive, AWS operation authorization to IAM,
 * filesystem and environment isolation to the container. What is left is the
 * one decision no external boundary can make for us, because it is about
 * intent rather than identity - whether this agent, in this workspace, should
 * be allowed to run this command at all.
 *
 * It is deliberately not the Cursor-compatibility layer. That lives in
 * runtime/cursor-compat-proxy and is engine-specific; this file must work
 * unchanged when the engine is Claude Code or Codex, which is what makes
 * section 37's multi-engine goal reachable without touching security code.
 *
 * WHY POLICY LIVES HERE AT ALL, since an LLM should never be the boundary:
 * in ACP mode Cursor does not apply its own .cursor/cli.json permissions. It
 * delegates every gated action to the client, and OpenHands Agent Server
 * auto-approves whatever it receives - verified on 2026-08-25, when
 * `aws sts get-caller-identity` ran to completion that way. This process is
 * the only component in the path that sees every request and is under our
 * control. It answers the request directly rather than forwarding it, so the
 * outcome does not depend on client behaviour.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startProxy } from "../acp-proxy/relay.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const POC_ROOT = path.resolve(HERE, "../..");
const POLICY_PATH = path.join(POC_ROOT, "config/acp-permissions.json");

function loadPolicy() {
  try {
    return JSON.parse(fs.readFileSync(POLICY_PATH, "utf8"));
  } catch (err) {
    // Fail closed: an unreadable or malformed policy must not mean "allow".
    process.stderr.write(
      `[policy-proxy] policy unreadable (${err.message}); denying all gated actions\n`,
    );
    return null;
  }
}

const policy = loadPolicy();
const auditPath = policy?.audit?.logPath ? path.resolve(POC_ROOT, policy.audit.logPath) : null;

function audit(decision, reason, toolCall) {
  if (!auditPath) return;
  if (decision === "allow" && !policy?.audit?.logAllowed) return;
  if (decision === "deny" && !policy?.audit?.logDenied) return;
  try {
    fs.appendFileSync(
      auditPath,
      JSON.stringify({
        ts: new Date().toISOString(),
        decision,
        reason,
        kind: toolCall?.kind ?? null,
        title: toolCall?.title ?? null,
      }) + "\n",
    );
  } catch {
    /* auditing must never break the session */
  }
}

/*
 * Records the untruncated session/request_permission payload.
 *
 * Kept because gating granularity depends on what the engine actually sends,
 * and that is not knowable from the specification. It is how we established
 * that a server exposing one generic tool collapses name-based allowlisting
 * unless arguments are visible - the finding that put AWS authorization on IAM
 * rather than on a string parser here.
 */
function dumpPayload(msg) {
  if (!policy?.audit?.debugPayloads || !auditPath) return;
  try {
    fs.appendFileSync(
      auditPath.replace(/\.jsonl$/, "-payloads.jsonl"),
      JSON.stringify({ ts: new Date().toISOString(), params: msg.params ?? null }) + "\n",
    );
  } catch {
    /* diagnostics must never break the session */
  }
}

/** Strip the markdown backticks Cursor wraps command titles in. */
function normaliseCommand(title) {
  return String(title ?? "").replace(/^`+|`+$/g, "").trim();
}

/** Split a compound command so every segment is evaluated independently. */
function splitSegments(command) {
  return command
    .split(/&&|\|\||;|\|/)
    .map((s) => s.trim())
    .filter(Boolean);
}

function commandBase(segment) {
  const first = segment.split(/\s+/)[0] ?? "";
  // Drop env-var prefixes such as FOO=bar cmd, and any path component.
  if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(first)) {
    const rest = segment.split(/\s+/).slice(1);
    return rest.length ? commandBase(rest.join(" ")) : "";
  }
  return first.split("/").pop() ?? "";
}

function matchesAny(patterns, text) {
  for (const pattern of patterns ?? []) {
    let re;
    try {
      re = new RegExp(pattern, "i");
    } catch {
      continue;
    }
    if (re.test(text)) return pattern;
  }
  return null;
}

/**
 * Cursor renders an MCP tool call as "<server>-<tool>: <tool>" with kind
 * "other". Anchoring on the repeated tool name is what lets a server name
 * containing hyphens still be split correctly.
 */
const MCP_TITLE = /^(.+)-([A-Za-z0-9_.]+):\s*\2\s*$/;

/**
 * Recovers the tool's arguments, which Cursor renders as a fenced JSON block in
 * toolCall.content. Verified against a real payload on 2026-08-25; without this
 * only the tool name is visible, and a tool that takes a query as a parameter
 * cannot be gated on what it was actually asked to do.
 */
function toolArguments(toolCall) {
  for (const entry of toolCall?.content ?? []) {
    const text = entry?.content?.text ?? entry?.text ?? "";
    const fenced = /```(?:json)?\s*([\s\S]*?)```/.exec(text);
    try {
      const parsed = JSON.parse((fenced ? fenced[1] : text).trim());
      if (parsed && typeof parsed === "object") return parsed;
    } catch {
      /* not the argument block; try the next content entry */
    }
  }
  return null;
}

/*
 * Statement-level gating for SQL tools.
 *
 * The only place left in this process that decides a security outcome by
 * reading a string, and it is here under protest: section 32 removes it once
 * DBHub plus a genuinely read-only database role prove the engine refuses
 * writes. Until that exists there is no hard boundary below it, so this is
 * better than nothing - but if it is ever the only thing between an agent and
 * the database, the database is wrong.
 *
 * Comments are stripped before the decision because a block comment and a
 * line comment can both hide the leading keyword, and multi-statement requests
 * are refused outright since the first keyword stops describing the request.
 */
function evaluateSql(toolCall) {
  const config = policy.mcp?.sqlQuery ?? {};
  const args = toolArguments(toolCall);
  const sql = String(args?.[config.argumentField ?? "sql"] ?? "").trim();

  if (!sql) {
    return { allow: false, reason: "could not read the SQL statement from the request" };
  }

  const stripped = sql
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/--[^\n]*/g, " ")
    .replace(/#[^\n]*/g, " ")
    .trim();

  const denied = matchesAny(config.deniedPatterns, stripped);
  if (denied) {
    return { allow: false, reason: `SQL matched denied pattern /${denied}/` };
  }

  const statements = stripped
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);

  if (statements.length > 1) {
    return { allow: false, reason: `${statements.length} statements in one request` };
  }

  const keyword = (statements[0] ?? "").split(/\s+/)[0].toLowerCase();
  const allowed = (config.allowedStatements ?? []).map((s) => s.toLowerCase());

  if (!allowed.includes(keyword)) {
    return {
      allow: false,
      reason: `SQL statement '${keyword || "(empty)"}' is not a permitted read statement`,
    };
  }
  return { allow: true, reason: `SQL '${keyword}' permitted` };
}

/*
 * MCP admission belongs to ToolHive, not here.
 *
 * The gateway refuses a non-admitted tool on tools/call and does not advertise
 * it on tools/list - both tested, in tests/security/run-toolhive-tests.sh and
 * run-rapid7-tests.sh, with results recorded under evaluations/. So a tool that
 * reaches the engine has already passed the gate, and re-checking the name here
 * would only re-implement the gate somewhere it can drift.
 */
function evaluateMcp(title, toolCall) {
  const match = MCP_TITLE.exec(title);
  if (!match) {
    // Fail closed. Every kind-"other" call observed so far has been an MCP
    // tool; anything unrecognised is denied and appears in the audit log,
    // which is the signal to look at it deliberately.
    return { allow: false, reason: `unrecognised non-execute tool '${title}'` };
  }

  const [, server, tool] = match;

  /*
   * No gateway in the path means nothing has vetted this call, so deny.
   *
   * This is what allows the MCP allowlist to be deleted from config rather
   * than merely bypassed: the ungoverned path became more restrictive, not
   * less. Setting NKB_AGENT_COMMAND is how the launcher signals that the
   * engine runs in the sandbox and therefore reaches MCP only through
   * ToolHive.
   */
  if (!process.env.NKB_AGENT_COMMAND) {
    return {
      allow: false,
      reason: `MCP is only available through the ToolHive gateway; ungoverned path has no admission control (tool '${server}:${tool}')`,
    };
  }

  if ((policy.mcp?.sqlQuery?.gatedTools ?? []).includes(`${server}:${tool}`)) {
    return evaluateSql(toolCall);
  }

  return { allow: true, reason: `MCP tool '${server}:${tool}' admitted by ToolHive` };
}

function evaluateCommand(command) {
  if (!command) return { allow: false, reason: "empty command title" };

  const denied = matchesAny(policy.deniedPatterns, command);
  if (denied) return { allow: false, reason: `matched denied pattern /${denied}/` };

  for (const segment of splitSegments(command)) {
    const base = commandBase(segment);
    if (!base) return { allow: false, reason: "could not determine command base" };
    if (!(policy.allowedCommands ?? []).includes(base)) {
      return { allow: false, reason: `'${base}' is not in allowedCommands` };
    }
    if (base === "git") {
      const sub = segment.split(/\s+/).slice(1).find((t) => !t.startsWith("-"));
      const allowedSubs = policy.git?.allowedSubcommands ?? [];
      if (!sub || !allowedSubs.includes(sub)) {
        return { allow: false, reason: `git subcommand '${sub ?? "(none)"}' is not read-only` };
      }
    }
  }

  return { allow: true, reason: "all segments permitted" };
}

/** @returns {{allow: boolean, reason: string}} */
function evaluate(toolCall) {
  if (!policy) return { allow: false, reason: "policy unavailable" };

  const kind = toolCall?.kind ?? "other";
  if (!(policy.allowedToolKinds ?? []).includes(kind)) {
    return { allow: false, reason: `tool kind '${kind}' is not permitted` };
  }

  const title = normaliseCommand(toolCall?.title);

  /*
   * Secret-bearing paths are checked for every tool kind, not just execute.
   *
   * Retained even though the sandbox mounts product source read-only, because
   * read-only does not mean unreadable and these files hold production
   * credentials. The export filter removes them from the workspace, so this is
   * the third of three layers rather than the first.
   */
  const paths = (toolCall?.locations ?? []).map((l) => l?.path ?? "").join(" ");
  const sensitive = matchesAny(policy.sensitivePatterns, `${title} ${paths}`);
  if (sensitive) {
    return { allow: false, reason: `matched sensitive pattern /${sensitive}/` };
  }

  switch (kind) {
    case "execute":
      return evaluateCommand(title);
    case "other":
      return evaluateMcp(title, toolCall);
    case "fetch":
    case "search":
      // Outbound queries are an egress channel: whatever the agent has read can
      // be embedded in the query string.
      return policy.network?.allowWebSearch
        ? { allow: true, reason: `network tool kind '${kind}' permitted` }
        : { allow: false, reason: `network tool kind '${kind}' disabled by policy` };
    default:
      return { allow: true, reason: `kind '${kind}' permitted` };
  }
}

function optionIdFor(options, wantedKinds) {
  for (const kind of wantedKinds) {
    const match = (options ?? []).find((o) => o.kind === kind);
    if (match) return match.optionId;
  }
  return null;
}

/*
 * The successor defaults to the Cursor compatibility proxy, which is where the
 * engine-specific translation lives. Overriding NKB_ACP_SUCCESSOR is how a
 * different engine is put in the chain: Claude Code and Codex speak standard
 * ACP and need no compatibility layer, so they are named directly.
 */
const successor =
  process.env.NKB_ACP_SUCCESSOR || path.join(POC_ROOT, "runtime/cursor-compat-proxy/index.mjs");
const args = process.argv.slice(2);

startProxy({
  name: "policy",
  command: successor.endsWith(".mjs") ? process.execPath : successor,
  args: successor.endsWith(".mjs") ? [successor, ...args] : args,
  logPath: process.env.NKB_ACP_TRACE || null,

  onAgentMessage(msg, ctx) {
    if (msg.method !== "session/request_permission" || msg.id === undefined) return false;

    const params = msg.params ?? {};
    const toolCall = params.toolCall ?? {};
    dumpPayload(msg);

    const { allow, reason } = evaluate(toolCall);
    audit(allow ? "allow" : "deny", reason, toolCall);

    const optionId = allow
      ? optionIdFor(params.options, ["allow_once", "allow_always"])
      : optionIdFor(params.options, ["reject_once", "reject_always"]);

    if (!optionId) {
      // No usable option offered; cancelling is the safe interpretation.
      ctx.toAgent({ jsonrpc: "2.0", id: msg.id, result: { outcome: { outcome: "cancelled" } } });
      return true;
    }

    if (!allow) {
      ctx.emitMessage(
        `\n> **Blocked by workspace policy** — \`${normaliseCommand(toolCall.title)}\`\n> ${reason}\n`,
        params.sessionId ?? ctx.sessionId,
      );
    }

    ctx.toAgent({
      jsonrpc: "2.0",
      id: msg.id,
      result: { outcome: { outcome: "selected", optionId } },
    });
    return true;
  },
});
