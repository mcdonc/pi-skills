---
name: reopen
description: Apply a PROMOTE decision on a default-closed triage item — drop it from the review queue (remove valid-reopened), ensure it's open, optionally assign / relabel / trust the author (opens an allowlist PR), and post an ack. The affirmative half of a triage decision (the other half is /keep-closed). Use when the user says /reopen <#> or says an item is legit / worth keeping / should be promoted.
---

# Reopen skill

You've reviewed an item in the triage queue (via `/triage-reopened` /
`/review-slop`) and decided it's a genuine contribution worth keeping open.
`/reopen` applies that decision: removes it from the queue, makes sure it's
open, and posts an ack. Optionally assigns it, relabels it, or trusts the author
(opens a small PR adding them to `.github/slop-allowlist` so their future
submissions bypass auto-close).

> The name is about the **decision** ("keep this open / promote it"), not the
> GitHub state — queue items are already reopened. `/keep-closed` is the inverse.

## Command

- `reopen.sh [--repo OWNER/NAME] [--assign LOGIN] [--add-label L]...
  [--trust-author] [--comment BODY|-] [--dry-run] <#>`

Flags:
- `--assign LOGIN` — assign the item (e.g. `--assign @me`). Best-effort.
- `--add-label L` (repeatable) — add labels (e.g. `triaged`, `bug`). Best-effort
  (a label that doesn't exist on the repo is skipped with a warning, not fatal).
- `--trust-author` — open a PR adding the item's author to `.github/slop-allowlist`.
- `--comment BODY` or `--comment -` (stdin) — override the default ack. **You**
  write a substantive reply that reflects what you found.
- `--dry-run` — print the gh commands without running them.

`<#>` is a bare number or a full issue/PR URL. `--repo` defaults to the cwd's
repo. The skill directory is the one holding this `SKILL.md`, e.g.
`~/.pi/agent/skills/reopen`.

## Invocation

Registers as `/skill:reopen`. Examples:

- `/skill:reopen 1042`
- `/skill:reopen 1042 --assign mcdonc --add-label triaged`
- `/skill:reopen 1042 --trust-author`  (this one's legit — also trust future work)
- `keep #1042 open, it's real`

## Workflow

When the user runs `/skill:reopen <#>` (or asks equivalently):

1. **Write the ack comment yourself** (the script just posts it). Make it specific:
   what you saw, why it's worth acting on, and the next step (who picks it up,
   what to do). Don't rely on the generic default unless the decision was trivial.
   Pass it via `--comment -` (stdin) so quotes/newlines are handled cleanly.
2. Run the script:
   ```bash
   <skill_dir>/scripts/reopen.sh <#> [--repo R] [--assign ...] [--add-label ...] \
     [--trust-author] [--comment -] [--dry-run] <<'EOF'
   <your ack>
   EOF
   ```
3. Report back: the item URL, what changed (queue label removed, assignee/labels
   if any), and — if `--trust-author` — the allowlist PR URL.

## Notes

- Removing `valid-reopened` is what drops the item from `/triage-reopened`. If you
  forget, it'll linger in the queue.
- `--trust-author` clones the repo shallowly to a temp dir, commits, and pushes a
  branch + PR; it never commits to the default branch. If the author is already
  allowlisted it no-ops (prints "(already in allowlist)").
- Optional mutations (assign/label) are best-effort; a missing label won't abort
  the rest of the decision.
