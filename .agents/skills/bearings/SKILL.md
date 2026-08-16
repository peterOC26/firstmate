---
name: bearings
description: >-
  Generate a "pick up where I left off" fleet digest from firstmate's live fleet state.
  Use when the captain invokes /bearings or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works".
  Plain /bearings is chat-only by default, while /bearings file explicitly writes the dated data/status-report-<YYYY-MM-DD>.md artifact; live PR enrichment remains opt-in and composes with file mode.
user-invocable: true
metadata:
  internal: true
---

# bearings

Generate a complete current snapshot from the fleet's current state, so the captain can resume in one read after a break, a night, or a context reset.
Plain `/bearings` returns only the concise six-column Kanban chat digest.
Only `/bearings file` writes the dated markdown report artifact and then returns the concise six-column Kanban chat digest linked to that report.
This skill is operationally read-only in both modes.
It never tears down a task, merges a PR, dispatches new work, steers a worker, answers a decision, cleans up work, mutates backlog or task state, or writes any file except the single dated report in explicit file mode.

## Invocation modes

- Plain `/bearings` gathers a fresh bounded snapshot and renders the six-column Kanban chat digest without creating, deleting, reading, or replacing `data/status-report-<YYYY-MM-DD>.md`.
- `/bearings file` gathers a fresh bounded snapshot, replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch, and renders the six-column Kanban chat digest with a link or path to that report.
- Treat `file` only as an explicit invocation option in the slash command.
- Do not treat natural-language requests such as "write a report", "save this", "persist it", or "make a file" as file mode unless the invocation explicitly includes the standalone `file` option.
- When the captain asks to include PRs, pass the snapshot command's live-PR opt-in.
- `/bearings include PRs` remains chat-only and makes the live-PR opt-in.
- `/bearings file include PRs` writes the dated report and makes the live-PR opt-in.

## What it does

1. **Gather live fleet state with one deterministic command.**
   Run `bin/fm-bearings-snapshot.sh` at invocation time and read its compact output.
   It is the single bounded, deterministic fleet-state source for Bearings and renders TOON by default.
   Do not create or consult a second fleet-state reader, parser contract, status-event-tail interpretation, visible-session recap, ad-hoc project probe, or ad-hoc `gh-axi`/`gh` query.
   The command's header and `--help` output own its exact fields, bounds, opt-ins, and output contract.
   Keep the default local-only read unless the captain asks to include PRs.
   For registered secondmates, use the snapshot's structured-home classification and provenance.
   A parent event or bounded terminal contradiction is fallback evidence, never authority over readable structured home state.
   Structured captain-held decisions come from `decision-hold-lifecycle` and appear under `decisions_open`.
   Do not scrape reports, visual-review artifacts, raw status-event tails, or visible conversation history to supplement current state.
   A queued item under `gates` only becomes "next work" when its blocker is gone and its time/date gate has arrived.
   Until then it stays queued with the reason.
   The `(main-inventory)` gate is an action-free integrity warning rather than queued work.
   Render it under Blocked with the related `omitted` disclosure, never invent an Under way row from backlog-only state, and never move it into Waiting on you.

2. **Compose the six-column Kanban chat digest from the fresh snapshot.**
   The gather step is deterministic; use `bin/fm-bearings-snapshot.sh --render chat` for the six captain-facing Markdown columns and carry its headings, item details, and empty sentences through verbatim.
   The render mode adds the presentation-only leading icon to each heading while leaving the structured snapshot contract unchanged.
   The chat response uses the six complete columns in the chat-response contract below, in the same order, each always present.
   Render from `board_columns` and `board_items`; the older `in_flight`, `decisions_open`, `landed`, and `gates` arrays are supporting detail and compatibility surfaces, not a separate reader.
   The render carries no disclosure, so you MUST add the step-1 snapshot's relevant `omitted` entries yourself: every `board <column> showing <n> of <m>` bound under that column, and the main-inventory integrity surfaces under Blocked, each with its `reveal` hint.
   Never present a bounded column as complete, and never edit a rendered heading, item line, or empty sentence to carry a disclosure.
   Plain mode stops here and writes no report artifact.

3. **In explicit file mode only, compose and replace the detailed report file.**
   Use `bin/fm-bearings-snapshot.sh --render file` for the six-column skeleton - headings, item lines, and empty sentences - and expand that skeleton into the full report below; the render itself contains none of the report's added detail.
   Carry the same `omitted` disclosures into the report exactly as step 2 requires for the chat.
   The report uses the same six complete columns as the chat, in the same order.
   Never read an earlier `data/status-report-*.md` to decide what to omit, include, describe as changed, or call current.
   Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date.
   If today's file already exists, delete it first, then create a new file from scratch.
   This is the only write allowed by the skill.
   The detailed report includes:
   - **Title** - `# Bearings - <day> <YYYY-MM-DD>` (use "Morning status" only when the captain specifically asks for a morning brief), followed by two or three sentences framing where things stand.
   - **Ready** - dispatchable queued work from the snapshot board.
   - **Held** - captain- or time-gated work that is not ready to dispatch.
   - **Blocked** - work waiting on another item or an action-free inventory integrity gate.
   - **Under way** - live workers from the snapshot board, with current state and useful pickup pointers (`data/<id>/report.md` files when relevant), plus every open PR that needs no captain action right now, each with its full `https://...` URL.
   - **Waiting on you** - every open decision, each PR ready to merge, and each needed credential or login, every PR with the full `https://...` URL, never a bare `#number`.
   - **Done** - the bounded current recent-completions baseline from structured state across the main fleet and every registered secondmate home, rendered in full on every run.
   After writing the file, return the concise six-column chat digest and include the report path or link without adding a seventh section.

## Chat-response contract

This skill is the one owner of the `/bearings` chat-response format; the snapshot and classifier own the data that feeds it, and no other file restates this contract.
Every `/bearings` chat response renders EXACTLY these six columns, in THIS order, and nothing else structural:

1. **Ready** - dispatchable queued work.
2. **Held** - captain- or time-gated work that is not ready to dispatch.
3. **Blocked** - queued work waiting on another item, plus action-free inventory integrity gates.
4. **Under way** - live workers, one line of current state per direct report, plus every open PR that needs no captain action right now.
5. **Waiting on you** - ONLY items that need the captain's own action now: a decision to make, a PR to approve or merge, a credential or login to provide, or a blocker only the captain can clear.
6. **Done** - the bounded current recent-completions baseline: merged PRs, completed scouts, and finished local-only merges across the main fleet and every registered secondmate home.

The captain-facing heading icons are presentation-only and are emitted by `fm-bearings-snapshot.sh --render chat|file`:

- **Ready** - 🟢
- **Held** - ⏸️
- **Blocked** - 🚧
- **Under way** - ⚙️
- **Waiting on you** - ❓
- **Done** - ✅

Rules that keep the contract unambiguous:

- Every column ALWAYS renders, even when empty; never omit a column.
- `board_columns` is the single source of the empty-state wording: render an empty column's `empty` sentence from `board_columns` verbatim, and never restate, paraphrase, or hardcode those sentences here or anywhere else.
- A column whose `omitted` entry reports a bound shows that disclosure and its `reveal` hint under the column's own lines; a disclosure is part of its column, never a seventh section.
- Every chat digest and file-mode report is a complete current snapshot, never a delta against a prior report.
- Done always renders the bounded current baseline, even when the same completions appeared in an earlier report.
- The six buckets are mutually exclusive, so every board item is forced into exactly one column by `board_items`.
- The strict boundary keeps action-free items OUT of Waiting on you: a working or validating task, a queued item blocked on another task or a date, landed work, a completed scout's report pointer, a declared `paused:` external wait, and a bare recorded PR with no merge-ready signal each belong to one of the other columns, never Waiting on you.
- An open PR is never absent from the board: it reaches Waiting on you only when the captain must review or merge it now, and otherwise reaches Under way with its current state (CI failing, checks still running, changes requested, needs an author update).
- Carry each item's `summary` and `detail` from `board_items` instead of re-deriving state wording from the older arrays, so a worker parked by a stopped validation run or a declared external wait keeps its honest parked or paused progress language and is never reported as a failure that needs a look.
- A secondmate's own row appears Under way only for `active_child_work`, and a home awaiting the captain reaches Waiting on you through its own decisions.
- Every secondmate hold reaches a column on its own terms: a hold recorded on the home's backlog boards through that queued item, and a hold that exists only because the home's own child is parked, paused, or blocked boards under Held as its own item. An unavailable home boards under Blocked as an unavailable-state gate. No home's held work is ever silently absent from all six columns, whatever else that home has queued.
- Do not suppress separately projected decisions, landed records, or gates from a `partial-structured` home merely because that secondmate's own row is `unknown`.
- The digest always carries the required direct address to the captain: when a rendered empty-state sentence already addresses the captain it satisfies the rule, and when every column is populated the address belongs in the framing around the rendered columns. Never edit a rendered column heading, item line, or empty sentence to insert it.
- Every PR appears as the full `https://...` URL; a shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same digest.
- The chat follows `AGENTS.md` section 9 and carries one scannable line per item.
- Detailed decisions, plans, full gate reasons, and evidence belong in the file only when file mode is explicit, so plain chat stays concise and file-mode chat stays materially shorter than that file.
- In file mode, include the report path or link inside the six-column digest without adding another heading.

## Tone and content rules

- The optional file-mode report is a private, captain-facing internal artifact that lives in gitignored `data/`, so unlike normal captain chat it MAY reference task ids, PR URLs, and repo names.
- The captain works with those directly and needs them to resume; keep the report organized and scannable, not a raw dump.
- Every PR reference is a full `https://...` URL, never a bare `#number`.
- Never include PHI or secret values; the report is an operational artifact, but it is still subject to the same security and compliance rules that govern everything else in this fleet.

## Supervision discipline

This skill changes no fleet state.
Do not tear down a task, merge a PR, dispatch queued work, steer a worker, answer a queued decision, clean up work, or mutate any `state/` or `data/` file other than the single report file in explicit file mode.
If the state you read suggests an action - a PR ready to merge, a queued item whose gate has arrived, or a needs-decision finding - name it in its column and leave the action to the normal lifecycle and configured authority rather than taking it from inside this skill.
