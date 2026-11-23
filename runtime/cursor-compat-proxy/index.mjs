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

/*
 * Reasoning relay.
 *
 * Cursor streams its reasoning as standard agent_thought_chunk updates, and the
 * relay already forwards them untouched. They still do not appear in Canvas,
 * and the reason is downstream of us: openhands/sdk/agent/acp_agent.py collects
 * those chunks into `accumulated_thoughts`, then emits the turn with
 * `thought=[]` and the text moved to `reasoning_content`. So the field Canvas
 * and our own smoke test read is hardcoded empty, and the field that has the
 * content only appears once, at the end of the turn.
 *
 * The result is a UI that shows tool calls happening with no indication of why,
 * which is the opposite of what an investigation tool should show: the reasoning
 * is the reviewable part, more so than the answer.
 *
 * So the reasoning is re-emitted as ordinary assistant text, the same mechanism
 * already used for cursor/create_plan. The original chunk is still forwarded -
 * this adds a rendering, it does not replace one - so reasoning_content stays
 * populated for anything that reads it.
 *
 * Buffered rather than streamed through verbatim. Thought text arrives in many
 * small fragments, and each is rendered as Markdown on arrival, so a blockquote
 * emitted a fragment at a time produces broken formatting rather than a quote
 * block. The buffer is flushed when the agent stops thinking and starts doing,
 * which is the moment the reasoning becomes worth reading anyway.
 *
 * Delete this along with the rest of the file if the SDK starts populating
 * `thought`, or if Canvas learns to render `reasoning_content`.
 */
function createThoughtBuffer(ctx) {
  let pending = [];

  return {
    add(text) {
      if (text) pending.push(text);
    },

    flush(sessionId) {
      if (!pending.length) return;
      const text = pending.join("").trim();
      pending = [];
      if (!text) return;
      // Quoted so it reads as commentary rather than as the answer. Every line
      // needs its own marker or Markdown ends the quote at the first newline.
      const quoted = text.split("\n").map((line) => `> ${line}`).join("\n");
      ctx.emitMessage(`> **Thinking**\n>\n${quoted}\n`, sessionId);
    },
  };
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

let thoughts;

startProxy({
  name: "cursor-compat",
  command: successor,
  args: args.length ? args : ["acp"],
  logPath: process.env.NKB_ACP_TRACE || null,

  onAgentMessage(msg, ctx) {
    thoughts ??= createThoughtBuffer(ctx);

    if (msg.method === "session/update") {
      const update = msg.params?.update;
      const sessionId = msg.params?.sessionId ?? ctx.sessionId;

      if (update?.sessionUpdate === "agent_thought_chunk") {
        if (update.content?.type === "text") thoughts.add(update.content.text);
        // Forwarded as well as buffered: the SDK still needs it to populate
        // reasoning_content on the finished turn.
        return false;
      }

      // Anything else on this session means the thinking turned into an action,
      // so the reasoning behind that action goes out ahead of it.
      thoughts.flush(sessionId);
      return false;
    }

    const handler = msg.method ? HANDLERS[msg.method] : undefined;
    if (!handler) {
      // A response to session/prompt ends the turn. Reasoning that produced no
      // subsequent update would otherwise be dropped on the floor.
      if (msg.id !== undefined && msg.result !== undefined) thoughts.flush(ctx.sessionId);
      return false;
    }

    const sessionId = msg.params?.sessionId ?? ctx.sessionId;

    // A plan or a question is also an action, so the reasoning that led to it
    // goes out first.
    thoughts.flush(sessionId);

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
