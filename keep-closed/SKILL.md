---
name: keep-closed
description: Apply a KEEP-CLOSED decision on a default-closed triage item — re-close it, drop it from the review queue (remove valid-reopened), and post an ack explaining how to get it reopened with more detail. The dismissive half of a triage decision (the other half is /reopen). Use when the user says /keep-closed <#> or says an item is slop / low-signal / should stay closed.
---

# Keep-closed skill

You've reviewed an item in the triage queue and decided it's low-signal — not
worth acting on. `/keep-closed` re-closes it, removes it from the queue, and
posts an ack that tells the author exactly how to get it reconsidered (reply with
specifics). The inverse of `/reopen`.

## Command

- `keep-closed.sh [--repo OWNER/NAME] [--comment BODY|-] [--dry-run] <#>`

Flags:
- `--comment BODY` or `--comment -` (stdin) — override the default ack. **You**
  write it; be honest and specific about what was missing.
- `--dry-run` — print the gh commands without running them.

`<#>` is a bare number or a full issue/PR URL. `--repo` defaults to the cwd's
repo. The skill directory is the one holding this `SKILL.md`, e.g.
`~/.pi/agent/skills/keep-closed`.

## Invocation

Registers as `/skill:keep-closed`. Examples:

- `/skill:keep-closed 1042`
- `/skill:keep-closed 1042 --comment -`  (your own dismissive-but-fair ack via stdin)
- `close #1042, it's slop`

## Workflow

When the user runs `/skill:keep-closed <#>` (or asks equivalently):

1. **Write the ack yourself.** The default is generic; a real reply helps a
   confused-but-genuine contributor understand what to add. Say concretely what
   was missing (no repro, no affected version, the cited file doesn't exist, the
   diff doesn't match the description). If the author clearly put in effort but
   missed something small, point at it specifically. Pass it via `--comment -`.
2. Run the script:
   ```bash
   <skill_dir>/scripts/keep-closed.sh <#> [--repo R] [--comment -] [--dry-run] <<'EOF'
   <your ack>
   EOF
   ```
3. Report back: the item URL and confirmation it's closed + out of the queue.

## Notes

- The ack is posted **before** the close so it lands while the item is still open
  (avoids any "can't comment on closed item" edge cases and keeps ordering clear).
- Removing `valid-reopened` is what drops the item from `/triage-reopened`.
- This intentionally **overrides** the auto-reopen the item earned. The label gate
  in the reopen workflow means a *future* comment from the author won't
  auto-reopen it again (no `auto-closed` label) — so only run `/keep-closed` after
  a real review, and use a clear ack so a genuine contributor knows to reply with
  substance (a maintainer can still reopen manually).
