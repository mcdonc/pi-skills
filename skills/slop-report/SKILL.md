---
name: slop-report
description: Delta slop report over a time window of issues/PRs opened in that window, each with a 0-100 slop score. The time-based safety net that catches false negatives the reopen path missed — legit items auto-closed that nobody challenged. Defaults to since-last-run (persisted cursor); also accepts an explicit period (since yesterday / last week / a date range) that does NOT advance the cursor. Use when the user says /slop-report or asks for a weekly slop summary / what did we miss.
---

# Slop-report skill

A **delta report** scoped to a time window: every issue/PR *opened* in that window,
each with a per-item slop score and the reasons behind it. This is the
time-based stage of the funnel — run weekly or after time away — to catch
**false negatives**: legitimate contributions that were auto-closed and that
nobody challenged (a new contributor who didn't know to comment, or who saw the
auto-close and gave up). Distinct from `/triage-reopened`, the live state-based
queue (cleared daily).

## Command

- `slop-report.sh [--repo OWNER/NAME] [PERIOD] [--limit N]` — emit JSON.

`PERIOD` (optional, positional):
- *(omitted)* — **since last run**: reads the persisted cursor, covers the new
  window, and **advances** the cursor. First-ever run (no cursor) falls back to
  the last 30 days.
- `"since yesterday"` / `"last week"` — relative windows. **Do not** advance the cursor.
- `"since 2026-06-01"` — from a date to today. **Does not** advance.
- `"2026-06-01..2026-06-15"` — explicit range. **Does not** advance.

Flag equivalents (also no advance): `--days N`, `--since DATE`, `--range A..B`.
`--limit N` caps the item count (default 100). `--repo` defaults to the cwd's repo.

The skill directory holds this `SKILL.md`, e.g. `~/.pi/agent/skills/slop-report`.

## Invocation

Registers as `/skill:slop-report`. Examples:

- `/skill:slop-report` — weekly since-last-run
- `/skill:slop-report since yesterday`
- `/skill:slop-report last week`
- `/skill:slop-report 2026-06-01..2026-06-15`
- `what slop did we miss last week?`

## Workflow

When the user runs `/skill:slop-report [period]` (or asks equivalently):

### 1. Run the report

```bash
<skill_dir>/scripts/slop-report.sh [--repo R] [PERIOD] [--limit N]
```

Read the JSON. Top level:

- `window` — `{from, to, mode, advanced_cursor}`. Note `advanced_cursor`: an
  explicit-period run leaves it `false` (a one-off `last week` won't swallow the
  next default run).
- `tally` — counts by outcome over the window.
- `items[]` — **pre-sorted**: false-negatives first. Each has `bucket`, `score`,
  `components`, `reasons`, `author`, `state`, `is_allowlisted`, `in_triage_queue`,
  `was_auto_closed`.

### 2. Read it in priority order (your job)

The sort already foregrounds what matters — render it that way:

1. **`false_negative`** (high score, still closed) — the legit items the reopen
   path missed. These are the whole point of the report. Surface each with its
   score, the top reasons it scored high, and recommend `/review-slop <#>` (then
   `/reopen <#>` if it holds up).
2. **`borderline`** — worth a `/review-slop` look if you have time.
3. **`confirmed_slop`** (low score, closed) — sanity check only; a sanity line
   ("N items auto-closed look correctly classified") is enough, don't itemize.
4. **`in_triage`** (demoted) — these are already in `/triage-reopened`. The report
   counts them in the tally but **does not re-demand a decision**; just note the
   count so you know they're handled elsewhere.

### 3. Report back

Lead with the window and the tally, then the false-negatives (if any) with a
one-line read each, then a one-line borderline/confirmed-slop summary. If there
are zero false-negatives, say so plainly — that's the good outcome.

## Notes

- **Grounding needs a checkout.** Run from within a clone of the target repo for
  file-path verification; otherwise `grounding` is neutral. A stale checkout may
  mark real paths as "not found".
- **Cursor** lives at `$XDG_STATE_HOME/pi-slop/cursor-<repo>.json` (one per repo).
  Delete it to reset to the 30-day fallback.
- **Search-index lag:** GitHub's search can trail label/state changes by ~10–60s;
  a just-reopened item may not yet carry `in_triage`.
- Author stats are fetched once per unique author (deduped), so cost scales with
  distinct authors, not item count.
