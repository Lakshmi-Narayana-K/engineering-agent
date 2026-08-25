#!/usr/bin/env python3
"""End-to-end smoke test across the full V0 path.

Exercises Agent Server -> ACP shim -> `agent acp` -> workspace, which is every
hop the browser uses except the React rendering itself. A pass here means the
architecture is wired correctly; a failure localises to the Agent Server hop,
because runtime/cursor/acp-probe.mjs already covers Cursor in isolation.

Usage: python3 runtime/smoke-test.py [--prompt TEXT] [--expect TEXT] [--timeout N]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

POC_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BASE_URL = os.environ.get("NKB_POC_BASE_URL", "http://localhost:8100")
DEFAULT_API_KEY = os.environ.get("LOCAL_BACKEND_API_KEY", "nkb-poc-local-key")
TERMINAL_STATUSES = {"idle", "finished", "error", "stuck", "paused"}


def request(method: str, path: str, base_url: str, api_key: str, payload: dict | None = None) -> dict:
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"X-Session-API-Key": api_key}
    # A Content-Type on a bodyless GET makes FastAPI look for a request body.
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(f"{base_url}{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            body = response.read().decode()
    except urllib.error.HTTPError as err:
        raise SystemExit(f"HTTP {err.code} on {method} {path}: {err.read().decode()[:500]}") from err
    return json.loads(body) if body else {}


def collect_agent_text(events: list[dict]) -> str:
    """Pull assistant-visible text out of the conversation event log.

    An ACP turn ends in an ActionEvent carrying a FinishAction rather than a
    MessageEvent, so both shapes have to be handled.
    """
    chunks: list[str] = []
    for event in events:
        if event.get("source") != "agent":
            continue

        for block in (event.get("llm_message") or {}).get("content") or []:
            if block.get("type") == "text" and block.get("text"):
                chunks.append(block["text"])

        action = event.get("action") or {}
        if action.get("message"):
            chunks.append(action["message"])

        for block in event.get("thought") or []:
            if block.get("type") == "text" and block.get("text"):
                chunks.append(block["text"])

    return "\n".join(chunks)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompt", default="Respond with exactly: CURSOR_ACP_CONNECTED")
    parser.add_argument("--expect", default="CURSOR_ACP_CONNECTED")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--workspace", default=str(POC_ROOT))
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--api-key", default=DEFAULT_API_KEY)
    parser.add_argument("--keep", action="store_true", help="do not delete the conversation afterwards")
    args = parser.parse_args()

    settings = request("GET", "/api/settings", args.base_url, args.api_key).get("agent_settings", {})
    print(f"agent_kind       : {settings.get('agent_kind')}")
    print(f"acp_server       : {settings.get('acp_server')}")
    print(f"acp_command      : {settings.get('acp_command')}")
    print(f"acp_session_mode : {settings.get('acp_session_mode')}")
    if settings.get("agent_kind") != "acp":
        print("FAIL: agent_kind is not 'acp'; run scripts/start.sh to configure it.")
        return 1

    print(f"\nworkspace        : {args.workspace}")
    print(f"prompt           : {args.prompt}\n")

    conversation = request(
        "POST",
        "/api/conversations",
        args.base_url,
        args.api_key,
        {
            "workspace": {"kind": "LocalWorkspace", "working_dir": args.workspace},
            # The server requires the agent to be named per conversation; reuse
            # the stored ACP settings so this matches what the browser sends.
            "agent_settings": {k: v for k, v in settings.items() if k != "schema_version"},
            "initial_message": {"role": "user", "content": [{"type": "text", "text": args.prompt}]},
        },
    )
    conversation_id = conversation.get("id")
    if not conversation_id:
        print(f"FAIL: no conversation id returned: {json.dumps(conversation)[:400]}")
        return 1
    print(f"conversation     : {conversation_id}")

    # The conversation reports 'idle' until the ACP subprocess has started, so
    # treat a terminal status as final only after 'running' has been observed.
    deadline = time.time() + args.timeout
    status = conversation.get("execution_status", "unknown")
    started = time.time()
    has_run = False
    print(f"  [   0.0s] status -> {status}")
    while time.time() < deadline:
        info = request("GET", f"/api/conversations/{conversation_id}", args.base_url, args.api_key)
        new_status = info.get("execution_status", "unknown")
        if new_status != status:
            print(f"  [{time.time() - started:6.1f}s] status -> {new_status}")
            status = new_status
        if status == "running":
            has_run = True
        if status == "waiting_for_confirmation":
            print("  conversation is waiting for confirmation; treating as terminal")
            break
        if has_run and status in TERMINAL_STATUSES:
            break
        time.sleep(2)
    else:
        print(f"FAIL: timed out after {args.timeout}s in status '{status}' (running observed: {has_run})")
        return 2

    # GET /events is a batch fetch by id; /events/search is the paged listing.
    # A long investigation easily exceeds one page, and the agent's final message is
    # the last event, so every page must be walked or the answer is lost.
    items = []
    page_id = None
    while True:
        query = f"limit=100&sort_order=TIMESTAMP"
        if page_id:
            query += f"&page_id={page_id}"
        events = request(
            "GET",
            f"/api/conversations/{conversation_id}/events/search?{query}",
            args.base_url,
            args.api_key,
        )
        if isinstance(events, list):
            items.extend(events)
            break
        items.extend(events.get("items", []))
        page_id = events.get("next_page_id")
        if not page_id:
            break

    text = collect_agent_text(items)

    print(f"\nevents           : {len(items)}")
    print("--- agent output ---")
    print(text.strip() or "(no agent text)")
    print("--- end ---")

    if not args.keep:
        request("DELETE", f"/api/conversations/{conversation_id}", args.base_url, args.api_key)

    if args.expect and args.expect not in text:
        print(f"\nFAIL: expected substring {args.expect!r} not found in agent output")
        return 3

    print(f"\nPASS: full path Agent Server -> ACP shim -> cursor agent acp -> {Path(args.workspace).name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
