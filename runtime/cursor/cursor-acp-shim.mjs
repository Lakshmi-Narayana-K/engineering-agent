#!/usr/bin/env node
/**
 * Minimal stdio shim between OpenHands Agent Server (ACP client) and `agent acp`.
 *
 * Standard ACP traffic is forwarded byte-for-byte in both directions. The shim
 * only touches Cursor's `cursor/*` extension methods, which Agent Server has no
 * handler for -- its ACPClient.ext_method returns `{}` for any unknown method,
 * so `cursor/ask_question` and `cursor/create_plan` receive a reply that does
 * not match their response schema and their payload never reaches the browser.
 *
 * For each intercepted method the shim does two things:
 *   1. injects the payload toward the client as a normal agent_message_chunk,
 *      so Agent Canvas renders it as ordinary assistant text
 *   2. answers Cursor with a schema-valid response, so the turn continues
 *
 * Everything else -- session/update, session/request_permission, tool calls --
 * is passed through so Agent Server keeps full control of the conversation.
 */
import { spawn } from "node:child_process";
import readline from "node:readline";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

// Agent Server controls this process's environment, so tracing defaults to on:
// an unanswered blocking request is otherwise invisible from the browser.
// Set NKB_ACP_SHIM_LOG=off to disable.
function resolveLogPath() {
  const configured = process.env.NKB_ACP_SHIM_LOG;
  if (configured === "off") return "";
  if (configured) return configured;
  const logDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../logs");
  try {
    fs.mkdirSync(logDir, { recursive: true });
    return path.join(logDir, "acp-shim.jsonl");
  } catch {
    return "";
  }
}

const LOG_PATH = resolveLogPath();
const log = LOG_PATH ? fs.createWriteStream(LOG_PATH, { flags: "a" }) : null;

function trace(direction, payload) {
  if (!log) return;
  log.write(`${new Date().toISOString()} ${direction} ${payload}\n`);
}

const SHIM_DIR = path.dirname(fileURLToPath(import.meta.url));
const POC_ROOT = path.resolve(SHIM_DIR, "../..");

/*
 * Ambient AWS credentials are stripped before `agent acp` starts.
 *
 * This shim is the last process under our control; everything below it --
 * agent acp, and every MCP server it spawns -- inherits this environment and is
 * driven by an LLM. On a developer machine AWS_PROFILE=default resolves to the
 * nxtwave-tech account (934...5156 is alpha; default is a different account
 * entirely), so inheriting it would silently point the agent at production
 * while every config file says alpha.
 *
 * Replacing rather than merely clearing matters too: with AWS_CONFIG_FILE set to
 * /dev/null the developer's other profiles are not merely unselected, they are
 * unreachable. The scoped identity in runtime/aws/credentials becomes the only
 * AWS identity that exists anywhere in the tree.
 *
 * Deployed on ECS this block is a no-op -- the credentials file is absent and
 * boto3 falls through to the task role, which is the intended behaviour.
 */
const AMBIENT_AWS_VARS = [
  "AWS_ACCESS_KEY_ID",
  "AWS_SECRET_ACCESS_KEY",
  "AWS_SESSION_TOKEN",
  "AWS_SECURITY_TOKEN",
  "AWS_PROFILE",
  "AWS_DEFAULT_PROFILE",
  "AWS_ROLE_ARN",
  "AWS_ROLE_SESSION_NAME",
  "AWS_WEB_IDENTITY_TOKEN_FILE",
  "AWS_SHARED_CREDENTIALS_FILE",
  "AWS_CONFIG_FILE",
];

// Read separately from loadPolicy(): the child is spawned before the policy
// const is initialised, and a function-local read keeps that ordering safe.
function awsSettings() {
  try {
    const raw = fs.readFileSync(path.join(POC_ROOT, "config/acp-permissions.json"), "utf8");
    return JSON.parse(raw).aws ?? {};
  } catch {
    return {};
  }
}

/*
 * Cursor reads its configuration from ~/.cursor, which on a developer machine is
 * the user's own. `agent acp` accepts no flag to redirect that -- it takes no
 * options at all -- so overriding HOME is the only mechanism available.
 *
 * This is what finally makes project-scoped MCP servers work. Verified across
 * three attempts (nkb-probe, cloudwatch-alpha twice): ACP loads only the global
 * ~/.cursor/mcp.json and silently ignores the project file, which is why
 * InsightIDR kept appearing while our own servers never did. Pointing HOME at a
 * directory we materialise means the config Cursor reads IS the repo's config.
 *
 * Declared config is copied from the tracked .cursor/ directory on every start,
 * so runtime/cursor-home is purely derived -- delete it and it rebuilds. Session
 * state and the MCP approval cache accumulate there and stay untracked.
 */
/*
 * Expands ${poc:<relpath>} and ${file:<relpath>} in the materialised MCP config.
 *
 * Cursor's config format offers no indirection: a server's command must be an
 * absolute path and its credentials must be literal strings in the env block.
 * Committing either is unacceptable -- one is machine-specific, the other is a
 * secret. Resolving at materialisation time satisfies both, since the tracked
 * file keeps placeholders and only the derived copy in the gitignored isolated
 * home carries real values.
 *
 * Walking the parsed structure rather than the raw text means a secret
 * containing quotes or backslashes is escaped correctly by JSON.stringify.
 *
 * A missing ${file:...} target leaves the placeholder intact, so the server
 * fails to authenticate visibly instead of starting with an empty credential.
 */
function resolvePlaceholders(value) {
  if (typeof value === "string") {
    return value.replace(/\$\{(poc|file):([^}]+)\}/g, (whole, kind, relative) => {
      const target = path.join(POC_ROOT, relative.trim());
      if (kind === "poc") return target;
      try {
        const contents = fs.readFileSync(target, "utf8").trim();
        return contents || whole;
      } catch {
        process.stderr.write(
          `[shim] unresolved \${file:${relative}} - that server will fail to authenticate\n`,
        );
        return whole;
      }
    });
  }
  if (Array.isArray(value)) return value.map(resolvePlaceholders);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, inner]) => [key, resolvePlaceholders(inner)]),
    );
  }
  return value;
}

function prepareCursorHome() {
  const home = path.join(POC_ROOT, "runtime/cursor-home");
  const dotCursor = path.join(home, ".cursor");
  fs.mkdirSync(dotCursor, { recursive: true });

  const cliSource = path.join(POC_ROOT, ".cursor/cli.json");
  if (fs.existsSync(cliSource)) {
    fs.copyFileSync(cliSource, path.join(dotCursor, "cli.json"));
  }

  const mcpSource = path.join(POC_ROOT, ".cursor/mcp.json");
  if (fs.existsSync(mcpSource)) {
    const target = path.join(dotCursor, "mcp.json");
    try {
      const parsed = JSON.parse(fs.readFileSync(mcpSource, "utf8"));
      fs.writeFileSync(target, JSON.stringify(resolvePlaceholders(parsed), null, 2), {
        mode: 0o600,
      });
    } catch (err) {
      process.stderr.write(`[shim] could not materialise mcp.json: ${err.message}\n`);
      fs.copyFileSync(mcpSource, target);
    }
  }

  // MCP servers are spawned by `agent acp`, not by us, and do not reliably
  // inherit AWS_SHARED_CREDENTIALS_FILE -- boto3 fell back to $HOME/.aws and
  // reported the profile as missing. Exposing the credential at the default
  // resolution path inside the isolated home fixes that, and also keeps absolute
  // machine paths out of every committed config file.
  //
  // A symlink rather than a copy: the credential stays a single file on disk with
  // one set of permissions to reason about, and rotating runtime/aws/credentials
  // takes effect immediately with nothing stale left behind.
  const credentials = path.join(POC_ROOT, "runtime/aws/credentials");
  if (fs.existsSync(credentials)) {
    const awsDir = path.join(home, ".aws");
    fs.mkdirSync(awsDir, { recursive: true });
    const link = path.join(awsDir, "credentials");
    try {
      fs.rmSync(link, { force: true });
      fs.symlinkSync(credentials, link);
    } catch (err) {
      process.stderr.write(`[shim] could not link AWS credentials: ${err.message}\n`);
    }
  }

  return home;
}

/*
 * Two sources, deliberately in this order. Deployed, the key is injected as an
 * environment variable from Secrets Manager and no file exists on disk; locally
 * it is a gitignored file. Reading the variable first means one code path serves
 * both, and -- importantly -- HOME isolation still engages in the container. A
 * file-only lookup would silently skip isolation there, and Cursor would fall
 * back to the image's empty ~/.cursor with no MCP servers configured at all.
 */
function readApiKey() {
  const fromEnv = (process.env.CURSOR_API_KEY ?? "").trim();
  if (fromEnv) return fromEnv;
  try {
    const keyPath = path.join(POC_ROOT, "runtime/cursor/api-key");
    return fs.readFileSync(keyPath, "utf8").trim() || null;
  } catch {
    return null;
  }
}

function buildChildEnv() {
  const env = { ...process.env };
  for (const key of AMBIENT_AWS_VARS) delete env[key];

  /*
   * In sandbox mode the child is a `docker run` wrapper, not Cursor itself, and
   * the container is the isolation boundary. Redirecting HOME here would isolate
   * the wrong process and break it: the Docker CLI reads its active context from
   * $HOME/.docker/config.json, so a redirected HOME makes it fall back to the
   * default socket - a different daemon, which does not have our image. The
   * failure surfaces as a confusing "repository does not exist" pull attempt.
   *
   * The credential and HOME juggling below exists only to isolate a Cursor
   * process running directly on the host. The container does that properly, at
   * the kernel, so none of it applies. This is the first of the environment
   * hacks the sandbox makes obsolete.
   */
  if (process.env.NKB_AGENT_COMMAND) return env;

  const settings = awsSettings();
  const credentials = path.join(POC_ROOT, "runtime/aws/credentials");

  if (settings.profile && fs.existsSync(credentials)) {
    env.AWS_SHARED_CREDENTIALS_FILE = credentials;
    env.AWS_CONFIG_FILE = "/dev/null";
    env.AWS_PROFILE = settings.profile;
    if (settings.region) env.AWS_REGION = settings.region;
  }

  const apiKey = readApiKey();
  if (apiKey) {
    // Only isolate HOME when a key is available. Without one the isolated home
    // has no session state either, and `agent acp` would fail to authenticate --
    // a confusing failure to debug, so fall back to the inherited HOME instead.
    env.HOME = prepareCursorHome();
    env.CURSOR_API_KEY = apiKey;
    // Cursor resolves its binary under the real home; keep that reachable so
    // changing HOME does not trigger a re-download of the runtime itself.
    env.CURSOR_AGENT_HOME = process.env.HOME ?? "";
  }

  return env;
}

const childArgs = process.argv.slice(2);

/*
 * Defaults to the Cursor CLI on PATH, which is the pre-sandbox behaviour.
 * Setting NKB_AGENT_COMMAND to scripts/agent-sandbox.sh runs Cursor inside the
 * container instead, with this process still answering permission requests from
 * outside it. Keeping the default unchanged means the sandbox is opt-in until
 * ToolHive restores MCP access over HTTP, which the container has no route to.
 */
const agentCommand = process.env.NKB_AGENT_COMMAND || "agent";
const child = spawn(agentCommand, childArgs.length ? childArgs : ["acp"], {
  stdio: ["pipe", "pipe", "inherit"],
  env: buildChildEnv(),
});

child.on("exit", (code, signal) => {
  process.exitCode = code ?? (signal ? 1 : 0);
  process.stdin.pause();
});

function toClient(obj) {
  const line = JSON.stringify(obj);
  trace("shim->client", line);
  process.stdout.write(line + "\n");
}

function toChild(obj) {
  const line = JSON.stringify(obj);
  trace("shim->agent", line);
  child.stdin.write(line + "\n");
}

/** Render text into the Canvas transcript as if the agent had said it. */
function emitMessage(sessionId, text) {
  if (!sessionId || !text) return;
  toClient({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      sessionId,
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
    },
  });
}

function renderQuestions(params) {
  const lines = [];
  if (params.title) lines.push(`**${params.title}**`);
  for (const question of params.questions ?? []) {
    lines.push(`\n${question.prompt}`);
    for (const option of question.options ?? []) lines.push(`- ${option.label}`);
  }
  lines.push("\nReply in chat with your choice and I will continue.");
  return lines.join("\n");
}

function renderPlan(params) {
  const lines = [];
  lines.push(`**Plan${params.name ? `: ${params.name}` : ""}**`);
  if (params.overview) lines.push(`\n${params.overview}`);
  if (params.plan) lines.push(`\n${params.plan}`);
  const todos = params.todos ?? [];
  if (todos.length) {
    lines.push("\nSteps:");
    for (const todo of todos) lines.push(`- [${todo.status}] ${todo.content}`);
  }
  return lines.join("\n");
}

/**
 * Handlers return a schema-valid result for the intercepted method. Returning
 * `undefined` means "do not intercept" and the message is forwarded normally.
 */
const EXTENSION_HANDLERS = {
  "cursor/ask_question": (params, sessionId) => {
    emitMessage(sessionId, renderQuestions(params));
    // Canvas has no multiple-choice widget, so decline the structured form.
    // The question text is already visible above; the user answers in chat.
    return { outcome: { outcome: "skipped", reason: "Client renders questions as chat text." } };
  },
  "cursor/create_plan": (params, sessionId) => {
    emitMessage(sessionId, renderPlan(params));
    return { outcome: { outcome: "accepted" } };
  },
  "cursor/update_todos": (params) => ({
    outcome: { outcome: "accepted", todos: params.todos ?? [] },
  }),
  "cursor/task": (params) => ({
    outcome: { outcome: "completed", agentId: params.agentId, durationMs: params.durationMs },
  }),
  "cursor/generate_image": () => ({
    outcome: { outcome: "rejected", reason: "Image generation is disabled in this workspace." },
  }),
};

/* ------------------------------------------------------------------ *
 * Permission enforcement
 *
 * In ACP mode Cursor does NOT apply its own .cursor/cli.json permissions.
 * It delegates every gated action to the client via session/request_permission,
 * and OpenHands Agent Server auto-approves whatever it receives. Verified on
 * 2026-08-25: `aws sts get-caller-identity` ran to completion this way.
 *
 * This shim is the only component that sees every request and is under our
 * control, so it is where policy has to live. Decisions are made here and the
 * request is answered directly rather than forwarded, which keeps the outcome
 * deterministic and independent of client behaviour.
 * ------------------------------------------------------------------ */

const POLICY_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../config/acp-permissions.json",
);

function loadPolicy() {
  try {
    return JSON.parse(fs.readFileSync(POLICY_PATH, "utf8"));
  } catch (err) {
    // Fail closed: an unreadable or malformed policy must not mean "allow".
    process.stderr.write(`[shim] policy unreadable (${err.message}); denying all gated actions\n`);
    return null;
  }
}

const policy = loadPolicy();
const auditPath = policy?.audit?.logPath
  ? path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..", policy.audit.logPath)
  : null;

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
 * Needed because gating granularity depends on what Cursor actually sends. A
 * server exposing one generic tool -- aws-api-mcp-server's `call_aws` runs any
 * CLI command -- collapses name-based allowlisting unless the arguments are
 * visible here. The title alone cannot distinguish `ecs describe-services` from
 * `ecs delete-service`, so this establishes whether argument-level gating is
 * possible rather than assuming either way.
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
 * only the tool name is visible, and a tool that takes a command as a parameter
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
 * aws-api-mcp-server exposes exactly one tool, `call_aws`, which runs any AWS
 * CLI command. Allowlisting it by name would therefore permit every API the
 * credentials can reach -- `ecs describe-services` and `ecs delete-service` are
 * indistinguishable at the tool level.
 *
 * IAM would still refuse the write, but that leaves IAM as the only control. The
 * arguments are visible in the payload, so gate on the real service and
 * operation and keep a third layer. This also makes the audit log name each AWS
 * call rather than recording hundreds of identical `call_aws` entries.
 */
function evaluateAwsCli(toolCall) {
  const config = policy.mcp?.awsApi ?? {};
  const args = toolArguments(toolCall);
  const command = String(args?.[config.argumentField ?? "cli_command"] ?? "").trim();

  if (!command) {
    return { allow: false, reason: "could not read the AWS CLI command from the request" };
  }
  // The server runs this through a CLI parser rather than a shell, but a
  // metacharacter here means the request is not the shape we think it is.
  if (/[;&|`$><\n]/.test(command)) {
    return { allow: false, reason: "AWS command contains shell metacharacters" };
  }

  const tokens = command.split(/\s+/);
  if (tokens[0] !== "aws") {
    return { allow: false, reason: `expected an 'aws' command, got '${tokens[0]}'` };
  }

  // Skip flags and their values are irrelevant here: service and operation are
  // always the first two positional tokens after `aws`.
  const positional = tokens.slice(1).filter((t) => !t.startsWith("-"));
  const [service, operation] = positional;
  const allowed = (config.allowedOperations ?? {})[service];

  if (!allowed) {
    return { allow: false, reason: `AWS service '${service ?? "(none)"}' is not allowlisted` };
  }
  if (!allowed.includes(operation)) {
    return {
      allow: false,
      reason: `'aws ${service} ${operation ?? "(none)"}' is not an allowlisted read operation`,
    };
  }
  return { allow: true, reason: `'aws ${service} ${operation}' allowlisted` };
}

/*
 * Statement-level gating for SQL tools.
 *
 * A read-only database user is the control that actually matters, and a reader
 * endpoint refuses writes at the engine. This is the layer above both: it stops
 * a destructive or exfiltrating statement before it reaches the network, and it
 * records what was asked. It is not a substitute for either -- if this is the
 * only thing standing between an agent and the database, the database is wrong.
 *
 * Comments are stripped before the decision because `/*! *\/ DROP` and
 * `-- x\nDROP` both hide the leading keyword, and multi-statement requests are
 * refused outright since the first keyword stops describing the whole request.
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

function evaluateMcp(title, toolCall) {
  const match = MCP_TITLE.exec(title);
  if (!match) {
    // Fail closed. Every kind-"other" call observed so far has been an MCP
    // tool; anything unrecognised is denied and shows up in the audit log,
    // which is the signal to allowlist it deliberately rather than by default.
    return { allow: false, reason: `unrecognised non-execute tool '${title}'` };
  }

  const [, server, tool] = match;
  const allowedTools = (policy.mcp?.allowedServers ?? {})[server];

  if (!allowedTools) {
    return { allow: false, reason: `MCP server '${server}' is not in mcp.allowedServers` };
  }
  if (!allowedTools.includes(tool)) {
    return { allow: false, reason: `MCP tool '${server}:${tool}' is not allowlisted` };
  }

  // Tools that take a command or query as a parameter need their argument
  // inspected; clearing the name check says nothing about what was requested.
  const gated = `${server}:${tool}`;
  if ((policy.mcp?.awsApi?.gatedTools ?? []).includes(gated)) {
    return evaluateAwsCli(toolCall);
  }
  if ((policy.mcp?.sqlQuery?.gatedTools ?? []).includes(gated)) {
    return evaluateSql(toolCall);
  }

  return { allow: true, reason: `MCP tool '${server}:${tool}' allowlisted` };
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

  // Secret-bearing paths are checked for every tool kind, not just execute.
  // repos/nkb_backend/env_prod.sh holds the production DB password, the Django
  // SECRET_KEY, and the SMS/push/email credentials, so a plain `read` of it is
  // as damaging as any command.
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

/** Answers session/request_permission directly. @returns true if handled. */
function handlePermissionRequest(msg) {
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
    toChild({ jsonrpc: "2.0", id: msg.id, result: { outcome: { outcome: "cancelled" } } });
    return true;
  }

  if (!allow) {
    emitMessage(
      params.sessionId ?? activeSessionId,
      `\n> **Blocked by workspace policy** — \`${normaliseCommand(toolCall.title)}\`\n> ${reason}\n`,
    );
  }

  toChild({ jsonrpc: "2.0", id: msg.id, result: { outcome: { outcome: "selected", optionId } } });
  return true;
}

// Track the active session so injected notifications carry a valid sessionId.
let activeSessionId = null;

readline.createInterface({ input: child.stdout }).on("line", (line) => {
  if (!line.trim()) return;
  trace("agent->shim", line);

  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    process.stdout.write(line + "\n");
    return;
  }

  if (msg.params?.sessionId) activeSessionId = msg.params.sessionId;
  if (msg.result?.sessionId) activeSessionId = msg.result.sessionId;

  if (msg.method === "session/request_permission" && msg.id !== undefined) {
    if (handlePermissionRequest(msg)) return;
  }

  const handler = msg.method ? EXTENSION_HANDLERS[msg.method] : undefined;
  if (handler && msg.id !== undefined) {
    const sessionId = msg.params?.sessionId ?? activeSessionId;
    let result;
    try {
      result = handler(msg.params ?? {}, sessionId);
    } catch (err) {
      toChild({ jsonrpc: "2.0", id: msg.id, error: { code: -32603, message: String(err) } });
      return;
    }
    toChild({ jsonrpc: "2.0", id: msg.id, result });
    return;
  }

  // Notification form of an extension method: surface it, nothing to answer.
  if (handler) {
    if (msg.method === "cursor/create_plan") {
      emitMessage(msg.params?.sessionId ?? activeSessionId, renderPlan(msg.params ?? {}));
    }
    return;
  }

  process.stdout.write(line + "\n");
});

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  if (!line.trim()) return;
  trace("client->shim", line);
  try {
    const msg = JSON.parse(line);
    if (msg.result?.sessionId) activeSessionId = msg.result.sessionId;
    if (msg.params?.sessionId) activeSessionId = msg.params.sessionId;
  } catch {
    /* forward malformed lines untouched */
  }
  child.stdin.write(line + "\n");
});

process.stdin.on("close", () => child.stdin.end());
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    child.kill(signal);
  });
}
