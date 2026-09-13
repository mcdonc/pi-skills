---
name: workon
description: Start work on a GitHub issue by creating a fresh git worktree off the default branch and printing the issue body. Use when the user says /workon <ISSUE#> or asks to begin working on an issue.
---

# Workon skill

Start implementing a GitHub issue in an isolated git worktree branched off the
repo's default branch, in one shot.

## Command

- `workon.sh [--dry-run] [--base <BRANCH>] <ISSUE#> [REPO]` — fetch issue,
  create worktree, print issue body.

Arguments:
- `--dry-run` — optional; print what would happen without creating anything.
- `--base <BRANCH>` — optional; base the worktree off `origin/<BRANCH>` instead
  of the repo's default branch (e.g. `--base stable/1.0` for release-tracked
  work). The value is a branch name **without** the `origin/` prefix.
- `<ISSUE#>` — required issue number.
- `[REPO]` — optional repo as `owner/name`. Defaults to the current directory's
  repo (detected via gh).

## What it does

1. Fetches the issue (title, state, url, body) via `gh issue view`.
2. Aborts unless the issue is **OPEN** (refuses to start work on closed issues).
3. Derives  a branch  name: `i<N>-<short-slug>`  (ASCII, kebab-case,  where the
   **total** name  length — "i" +  issue num +  slug together — is  capped, not
   just the slug). The cap defaults to 16 (the global AGENTS.md worktree rule);
   set  `PI_WORKON_MAX_NAME_LEN`  to  override it  per-repo  or  per-invocation
   (e.g. a  repo whose convention caps  worktree dir names at  20 chars exports
   `PI_WORKON_MAX_NAME_LEN=20`).
4. If a worktree already exists for that branch, **reuses it** (prints the path)
   instead of creating a duplicate.
5. Otherwise creates a worktree off `origin/<base>` — the repo's default
   branch, or the one named by `--base` — at `<repo_root>/.worktrees/<branch>`,
   ensuring `.worktrees/` is in `.git/info/exclude` (local-only; does not modify
   the shared `.gitignore`).
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
   new branch.

5. **Rebase onto the latest default branch before pushing.** Main may have
   moved since the worktree was created (other PRs merged — often via squash,
   which rewrites the base SHA with no ancestry link to the branch). A stale
   base shows up as spurious "conflicts" on PR creation even when there's no
   real divergence. Before the first push, and again whenever the PR sits
   open while other PRs land:
   ```bash
   git fetch origin <default-branch>
   git rebase origin/<default-branch>
   # resolve any conflicts, then:
   git push -u origin HEAD --force-with-lease
   ```
   Re-run the full test suite after the rebase to confirm the merge is clean.

6. **Open the PR.** Once the rebase is clean and the suite passes, create
   the PR (`gh pr create` from the worktree) with a proper title and body —
   before any review runs, so the review can be posted on the PR.

7. **Review the branch — unless one has already been done.** Right after
   opening the PR, run the `/review` skill against the branch (the reviewer
   runs in the background and takes minutes — do changelog and other chores
   while it runs). Triage its findings, land fixes, and push them to the same
   branch; the open PR updates automatically. Skip the review only when one
   has already FINISHED on this branch's history (a completed review whose
   recorded head is an
   ancestor of — or equal to — the current HEAD; review records live under
   `~/.pi/agent/reviews/<owner>/<repo>/<branch>/<ts>/`):
   ```bash
   wt=<WORKTREE_PATH>
   url=$(git -C "$wt" config --get remote.origin.url); url=${url%.git}; url=${url#*://}; url=${url#*:}
   slug="$(basename "$(dirname "$url")")/$(basename "$url")"
   branch=$(git -C "$wt" branch --show-current); head=$(git -C "$wt" rev-parse HEAD)
   reviewed=no
   for d in "$HOME/.pi/agent/reviews/$slug/$branch"/*/; do
     [ -f "$d/done" ] || continue
     rh=$(grep -oP '^head=\K[0-9a-f]+' "$d/meta" 2>/dev/null)
     if [ -n "$rh" ] && git -C "$wt" merge-base --is-ancestor "$rh" "$head" 2>/dev/null; then reviewed=yes; break; fi
   done
   # reviewed=yes -> skip; reviewed=no -> run /review first
   ```
   The ancestor rule means post-review fix commits do not trigger another
   review (the reviewed base is contained in HEAD) — the footer's
   `rvw ✓ +N` is expected and fine. A genuinely unrelated new head still
   gets reviewed.

8. **Attach the review to the PR.** When the review has finished and its
   findings are addressed, post the reviewer's output as a
   PR comment so the review travels with the PR — reusing `$slug`/`$branch`
   from step 7, pick the newest finished run and post its text:
   ```bash
   pr=$(gh pr view --json number -q .number)   # from the worktree
   newest=""
   for d in "$HOME/.pi/agent/reviews/$slug/$branch"/*/; do
     [ -f "$d/done" ] && [ -s "$d/review.md" ] && newest="$d"
   done
   if [ -n "$newest" ]; then
     {
       echo "## Fresh-eyes review"
       echo
       cat "$newest/review.md"
     } > /tmp/review-comment.md
     gh pr comment "$pr" --body-file /tmp/review-comment.md
   fi
   ```
   Use `--body-file <path>` exactly as shown — never `--body -` or
   `--body <(...)` (both pass literal junk instead of the content).

9. When finished (PR merged), clean up with the `/skill:merge <PR#>` skill,
   which removes the worktree and deletes the branch.

## Notes

- Worktrees live at `<repo_root>/.worktrees/<branch>` and are excluded from git
  status via `.git/info/exclude` (no changes to `.gitignore`).
- The base is `origin/<default-branch>` by default (fetched fresh), so each
  worktree starts from the latest default tip at **workon time** — not from
  any local dirty state. Pass `--base <BRANCH>` to base the worktree off a
  different branch (e.g. a release/stable branch) instead. But "latest at
  workon time" ≠ "latest at push time": main can move while you work.
  **Rebase before pushing** (Workflow step 5). This is especially important
  on repos that squash-merge: a squash landing after workon replaces the
  linear history with a fresh commit SHA, so the branch's parent no longer
  matches main even when the content is identical — producing phantom
  conflicts on PR creation.
- If the issue is not OPEN, the script aborts. Reopen it first if you really want
  to work on a closed issue.
- **The PR is opened before the review runs.** Workflow steps 6–8: create the
  PR, review the branch, then post the review as a PR comment. Review records
  live under `~/.pi/agent/reviews/` — the same records the worktree-indicator
  footer's `rvw` segment reads. Post-review fixes are pushed to the same
  branch and update the open PR.
- Re-running the skill on the same issue reuses the existing worktree rather
  than clobbering it.
