---
name: workon
description: Start work on a GitHub issue by creating a fresh git worktree off the default branch and printing the issue body. Use when the user says /workon <ISSUE#> or asks to begin working on an issue.
---

# Workon skill

Start implementing a GitHub issue in an isolated git worktree branched off the
repo's default branch, in one shot.

## Command

- `workon.sh [--dry-run] <ISSUE#> [REPO]` — fetch issue, create worktree, print
  issue body.

Arguments:
- `--dry-run` — optional; print what would happen without creating anything.
- `<ISSUE#>` — required issue number.
- `[REPO]` — optional repo as `owner/name`. Defaults to the current directory's
  repo (detected via gh).

## What it does

1. Fetches the issue (title, state, url, body) via `gh issue view`.
2. Aborts unless the issue is **OPEN** (refuses to start work on closed issues).
3. Derives a branch name: `issue-<N>-<slug-of-title>` (ASCII, kebab-case,
   truncated to 60 chars).
4. If a worktree already exists for that branch, **reuses it** (prints the path)
   instead of creating a duplicate.
5. Otherwise creates a worktree off `origin/<default-branch>` at
   `<repo_root>/.worktrees/<branch>`, ensuring `.worktrees/` is in
   `.git/info/exclude` (local-only; does not modify the shared `.gitignore`).
6. Prints a summary with `WORKTREE_PATH=`, `BRANCH=`, `ISSUE_URL=`, and the full
   issue body.

The script does **not** change the caller's cwd (a subprocess cannot). The agent
must run subsequent commands inside the printed `WORKTREE_PATH`.

## Invocation

This skill registers as `/skill:workon`. Example user requests:

- `/skill:workon 825`
- `/skill:workon 825 mcdonc/klangk`
- `start work on issue 825` (the model maps this to the script)

## Workflow

When the user runs `/skill:workon <ISSUE#> [repo]` (or asks equivalently):

1. Run the script with the issue number (and optional repo):
   ```bash
   <skill_dir>/scripts/workon.sh <ISSUE#> [REPO]
   ```
   The skill directory is the one containing this `SKILL.md` file, e.g.
   `~/.pi/agent/skills/workon`.

2. From the script's output, capture the three machine-readable lines:
   - `WORKTREE_PATH=<path>` — where to work.
   - `BRANCH=<branch>` — the branch checked out there.
   - `ISSUE_URL=<url>` — the issue permalink.

3. **Switch context to the worktree**: run all subsequent implementation
   commands (edits, builds, tests, git commits) inside `WORKTREE_PATH`. Use
   `cd <WORKTREE_PATH>` for shell commands, or read/edit files using their
   absolute path under `WORKTREE_PATH`.

4. **Implement the issue**: read the printed issue body, break it into concrete
   steps, make code changes, run tests/linters, and commit incrementally on the
   new branch. Open a PR when done (`gh pr create` from the worktree).

5. When finished (PR merged), clean up with the `/skill:merge <PR#>` skill,
   which removes the worktree and deletes the branch.

## Notes

- Worktrees live at `<repo_root>/.worktrees/<branch>` and are excluded from git
  status via `.git/info/exclude` (no changes to `.gitignore`).
- The base is always `origin/<default-branch>` (fetched fresh), so each worktree
  starts from the latest default tip — not from any local dirty state.
- If the issue is not OPEN, the script aborts. Reopen it first if you really want
  to work on a closed issue.
- Re-running the skill on the same issue reuses the existing worktree rather
  than clobbering it.
