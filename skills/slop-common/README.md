# slop-common

**Shared library for the slop-policy skills.** This is **not** a skill — it has
no `SKILL.md` and is never loaded directly by the agent. The five policy skills
source these helpers:

- `triage-reopened`
- `review-slop`
- `reopen`
- `keep-closed`
- `slop-report`

## Modules

| file | purpose |
|------|---------|
| `repo.sh`    | resolve `owner/name` from `--repo` or cwd |
| `labels.sh`  | the two policy labels + allowlist membership |
| `collect.sh` | fetch author stats (account age, prior contributions) |
| `score.sh`   | the **0–100 slop score** (higher = more likely legit) |

## How skills source it

Each skill's script resolves this directory with a three-tier fallback:

```bash
COMMON_DIR="${SLOP_COMMON_DIR:-}"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$(dirname "$(readlink -f "$0")")/../../slop-common"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$HOME/.pi/agent/skills/skills/slop-common"
source "$COMMON_DIR/score.sh"
```

So: explicit override → sibling-of-skill (works when all skills sit together in
`~/.pi/agent/skills/`) → canonical home. If none resolve, the script errors.

## Label model (post-PR #1050)

| label | meaning | set by | removed by |
|-------|---------|--------|------------|
| `auto-closed`    | eligible-for-auto-reopen (ephemeral) | `auto-close` workflow, on open | `auto-reopen` workflow, on reopen |
| `valid-reopened` | in the human triage queue | `auto-reopen` workflow, on reopen | `/reopen` or `/keep-closed` skill |

The queue is just `gh issue list --label valid-reopened --state open` — GitHub is
the source of truth, no local decided-state file.
