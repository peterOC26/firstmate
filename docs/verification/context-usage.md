# Worker context usage verification

This record supports the read-only metrics used by `bin/fm-context-usage.sh`.
It does not establish or claim a Firstmate context ceiling.

## 2026-08-12 installed harness evidence

Claude Code `2.1.220` was run in a controlled scratch session and compared with its `/context` display.
The exact command used to inspect the last finalized assistant record was:

```sh
jq -c 'select(.type=="assistant" and .message.usage != null and .message.stop_reason != null) |
  {sessionId, cwd, version, stop_reason:.message.stop_reason,
   usage:{input_tokens:.message.usage.input_tokens,
          cache_creation_input_tokens:.message.usage.cache_creation_input_tokens,
          cache_read_input_tokens:.message.usage.cache_read_input_tokens,
          output_tokens:.message.usage.output_tokens}}' \
  /Users/zabi/.claude/projects/-Users-zabi-orca-workspaces-Firstmate-fm-fm-ctx-budget-plan-r1/e7b4a490-3ec3-4cf9-8f7c-04a58f49b055.jsonl | tail -1
```

Its exact output was:

```json
{"sessionId":"e7b4a490-3ec3-4cf9-8f7c-04a58f49b055","cwd":"/Users/zabi/orca/workspaces/Firstmate/fm-fm-ctx-budget-plan-r1","version":"2.1.220","stop_reason":"end_turn","usage":{"input_tokens":2,"cache_creation_input_tokens":30047,"cache_read_input_tokens":0,"output_tokens":4}}
```

The conservative reader metric was therefore `2 + 30047 + 0 + 4 = 30053`, while Claude displayed `30k/1m tokens (3%)`: agreement within the display's rounding, against a `1m` runtime maximum that the transcript itself does not report (Claude rows leave `context_window` empty for that reason).

Codex CLI `0.147.0` was run in a controlled scratch session and compared with `/status`.
The exact command used to inspect the final complete record was:

```sh
jq -c 'select(.type=="event_msg" and .payload.type=="token_count") |
  {last_token_usage:.payload.info.last_token_usage,
   model_context_window:.payload.info.model_context_window}' \
  /Users/zabi/.codex/sessions/2026/08/12/rollout-2026-08-12T01-00-53-019ff30e-af3b-7183-adfc-1e5e2a404ecc.jsonl | tail -1
```

Its exact output was:

```json
{"last_token_usage":{"input_tokens":24204,"cached_input_tokens":5504,"cache_write_input_tokens":0,"output_tokens":87,"reasoning_output_tokens":80,"total_tokens":24291},"model_context_window":258400}
```

Codex displayed `Context window: 95% left (24.3K used / 258K)`.
The transcript's `last_token_usage.total_tokens=24291` agrees with the displayed `24.3K` after rounding, while cumulative `total_token_usage` and the displayed percentage are not used.

Both readings are bounded and best-effort by design: each scan reads a fixed-size window at the end of the transcript (plus the head slice carrying Codex's `session_meta` identity line), skips a malformed or truncated line inside it, and reports `unknown` when the newest usage record has already scrolled past that window.
The numbers above are therefore reproducible for a live session, not a guaranteed exact account of an arbitrarily long one.

Refresh the portable binding, bounded-window, compaction, malformed/truncated JSONL, multiple-session, alternate-root, relaunch, remote-unknown, and warning-transition evidence with:

```sh
bin/fm-test-run.sh tests/fm-context-usage.test.sh
```
