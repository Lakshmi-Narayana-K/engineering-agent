#!/usr/bin/env node
/*
 * Cursor compatibility proxy.
 *
 * Translates Cursor's non-standard cursor/* ACP methods into things Agent
 * Canvas understands. It holds no policy and makes no security decisions - if
 * you find yourself adding one here, it belongs in
 * runtime/acp-policy-proxy/index.mjs instead.
 *
 * WHY IT EXISTS, since section 13 says to delete it if Canvas renders these
 * events natively: it does not. Searching the installed
 * @openhands/agent-canvas and agent-server for `ask_question` and
 * `create_plan`, excluding vendored editor code, returns nothing. Canvas does
 * use the official ACP SDK, which models the standard protocol - and cursor/*
 * is not in the standard schema, so there is nothing upstream to inherit.
 *
 * Without this, Cursor's questions and plans do not merely render badly: an
 * unanswered request/response method leaves the engine waiting for a reply
 * that never arrives, which stalls the turn.
 *
 * It is separated from the policy proxy rather than merged into it for two
 * reasons. It is engine-specific, so it must be removable from the chain when
 * the engine is Claude Code or Codex - both of which speak standard ACP. And
 * it is the part most likely to change under us, since it tracks another
 * vendor's extensions; keeping that churn away from security code is the whole
 * point of the split.
 *
 * Delete this component entirely when either Canvas learns cursor/*, or the
 * platform stops using Cursor.
 */

import { startProxy } from "../acp-proxy/relay.mjs";

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
 * Each handler returns a schema-valid result for the method it intercepts.
 * The outcomes are chosen to be honest about what Canvas can actually do -
 * declining the structured form of a question is better than accepting it and
 * silently dropping the user's ability to answer.
 */
const HANDLERS = {
  "cursor/ask_question": (params, ctx, sessionId) => {
    ctx.emitMessage(renderQuestions(params), sessionId);
    // Canvas has no multiple-choice widget, so decline the structured form.
    // The question text is already visible above; the user answers in chat.
    return { outcome: { outcome: "skipped", reason: "Client renders questions as chat text." } };
  },
  "cursor/create_plan": (params, ctx, sessionId) => {
    ctx.emitMessage(renderPlan(params), sessionId);
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

/*
 * Defaults to the Cursor CLI on PATH. The launcher sets NKB_AGENT_COMMAND to
 * scripts/agent-sandbox.sh so the engine runs in the container while this
 * process stays outside it - which is what lets the proxies keep answering
 * permission requests that the sandbox itself must not be able to influence.
 *
 * No credential handling here on purpose: agent-sandbox.sh reads the Cursor key
 * from runtime/cursor/api-key itself and injects it at the container boundary,
 * so no secret passes through the protocol layer.
 */
const successor = process.env.NKB_AGENT_COMMAND || "agent";
const args = process.argv.slice(2);

startProxy({
  name: "cursor-compat",
  command: successor,
  args: args.length ? args : ["acp"],
  logPath: process.env.NKB_ACP_TRACE || null,

  onAgentMessage(msg, ctx) {
    const handler = msg.method ? HANDLERS[msg.method] : undefined;
    if (!handler) return false;

    const sessionId = msg.params?.sessionId ?? ctx.sessionId;

    // Notification form: there is no id to answer, so just surface it.
    if (msg.id === undefined) {
      if (msg.method === "cursor/create_plan") {
        ctx.emitMessage(renderPlan(msg.params ?? {}), sessionId);
      }
      return true;
    }

    let result;
    try {
      result = handler(msg.params ?? {}, ctx, sessionId);
    } catch (err) {
      ctx.toAgent({ jsonrpc: "2.0", id: msg.id, error: { code: -32603, message: String(err) } });
      return true;
    }
    ctx.toAgent({ jsonrpc: "2.0", id: msg.id, result });
    return true;
  },
});
