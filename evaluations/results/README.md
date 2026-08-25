# Evaluation Results

One file per question run, named `qNN-<slug>.md`. Each records the prompt as sent, the
agent's answer, a grade against the expected answer in
[`../questions.md`](../questions.md), and any observation about *how* the agent reached
the answer.

Runs go through the full path: Agent Canvas HTTP API → OpenHands Agent Server → ACP shim →
`agent acp` → the three symlinked repositories.

Reproduce a single run with:

```bash
python3 runtime/smoke-test.py --timeout 420 --keep --prompt "<question>"
```

The `FAIL: expected substring 'CURSOR_ACP_CONNECTED' not found` line at the end of such a
run is expected — that is the harness's default smoke-test assertion, not a grade on the
answer.
