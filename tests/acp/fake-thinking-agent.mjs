#!/usr/bin/env node
/*
 * A stand-in for the Cursor CLI that emits exactly the ACP traffic the reasoning
 * relay cares about: thought chunks in fragments, then an action, then a reply.
 *
 * It exists because the behaviour under test is a transformation of a message
 * stream, and the real engine is a slow, non-deterministic way to produce one.
 *
 *   NKB_AGENT_COMMAND=node node runtime/cursor-compat-proxy/index.mjs \
 *     tests/acp/fake-thinking-agent.mjs </dev/null
 *
 * Expect each run of thought chunks to be forwarded unchanged AND followed by a
 * single agent_message_chunk holding the whole run as a "> **Thinking**" block,
 * emitted before the tool_call that follows it.
 */

const say = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");
const sessionId = "sess-test";

const update = (u) => say({
  jsonrpc: "2.0",
  method: "session/update",
  params: { sessionId, update: u },
});

process.stdin.on("data", () => {});

setTimeout(() => {
  // Reasoning arrives split mid-sentence and across a newline, which is the
  // case that breaks any implementation that emits fragments as they land.
  update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "I should check the\n" } });
  update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "sheet before answering." } });

  // An action. The buffered reasoning must be flushed ahead of this.
  update({
    sessionUpdate: "tool_call",
    toolCallId: "tc-1",
    title: "sheets_get_values",
    status: "pending",
  });

  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Here is the answer." } });

  // A second reasoning run with nothing after it, to prove end-of-turn flushing.
  update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Nothing else to do." } });

  say({ jsonrpc: "2.0", id: 1, result: { stopReason: "end_turn" } });
  setTimeout(() => process.exit(0), 50);
}, 30);
