---
name: triage-reopened
description: List the default-closed policy's triage queue — open issues and PRs labeled valid-reopened (auto-closed, then reopened by a human-sounding comment). Each item comes with its author, allowlist status, a body excerpt, and the recent comments (so the triggering human engagement is visible). Use when the user says /triage-reopened or asks what's in the slop review queue / what needs deciding.
---

# Triage-reopened skill

List the items that passed the default-closed policy's first human filter — they
were auto-closed, someone left a substantive comment, and `auto-reopen` reopened
them and tagged them `valid-reopened`. These are the **live action queue**:
highest-signal items, meant to be cleared daily. This is the state-based stage of
the funnel (see `/slop-report` for the time-based safety net).

## Command

- `triage-reopened.sh [--repo OWNER/NAME] [--score]` — list the queue, emit JSON.

`--score` attaches a full 0–100 slop score to each item (heavier: fetches author
stats + grounds cited paths per item). Off by default — the queue is usually
short and `/review-slop <#>` is the deeper dive. Use `--score` only to prioritize
a longer queue at a glance.

`--repo` defaults to the repo of the current working directory.

The skill directory is the one containing this `SKILL.md`, e.g.
`~/.pi/agent/skills/triage-reopened`.

## Invocation

Registers as `/skill:triage-reopened`. Examples:

- `/skill:triage-reopened`
- `/skill:triage-reopened --repo mcdonc/klangk --score`
- `what's in the slop review queue?`

## Workflow

When the user runs `/skill:triage-reopened` (or asks equivalently):

### 1. List the queue

```bash
<skill_dir>/scripts/triage-reopened.sh [--repo OWNER/NAME] [--score]
```

Read the JSON. Top level: `repo`, `label` (the queue label), `count`, `queue[]`.
Each queue item:

- `number`, `kind` (`issue`|`pr`), `title`, `url`, `author`, `created_at`, `state`.
- `is_allowlisted` — whether the author bypasses auto-close (trusted).
- `body_excerpt` — first 300 chars of the description.
- `recent_comments[]` — `author` + `body` + `created_at` for the latest comments.
  **The human follow-up that triggered the reopen is in here**, usually sitting
  between the bot's close-comment and its "Reopened for maintainer review" ack.
- `score` (only with `--score`) — `{score, components, reasons}`.

### 2. Summarize and prioritize (your job)

If `count == 0`: say the queue is empty and stop.

Otherwise, present a compact, **prioritized** list — not a raw dump. For each
item, in priority order:

1. Items whose `recent_comments` show a substantive, specific human reply (names a
   symptom, a file, a version, asks a real question) — act on these first.
2. Items from `is_allowlisted` authors or with a high `score` (if `--score`).
3. Items that look like low-effort reopen-begging despite passing the filter —
   these may warrant `/keep-closed`.

For each, give: `#number`, title, the triggering comment (quoted briefly), and a
one-line read. Then recommend a per-item next step:

- `/review-slop <#>` — if you need the full deep-dive (diff, grounding, score) to
  decide.
- `/reopen <#>` — to promote (drop from the queue, keep open).
- `/keep-closed <#>` — to re-close (drop from the queue).

### 3. Report back

Lead with the count and the single highest-priority item; then the rest in
priority order. Keep it scannable — the maintainer is triaging, not reading.

## Notes

- The queue is `gh search` for `label:valid-reopened state:open` — GitHub is the
  source of truth, so the skill is stateless and works on any machine.
- GitHub's search index lags label changes by ~10–60s; a just-reopened item may
  not appear for a minute. Re-run if you expect something that isn't there yet.
- `/slop-report` (different cadence) **demotes** any item also sitting in this
  queue, so the maintainer never decides on the same item twice.
