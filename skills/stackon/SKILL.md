---
name: stackon
description: Start work on a GitHub issue stacked on top of an in-flight PR. Creates a fresh git worktree+branch based off the PR's head branch (not main), so you can make progress on a dependent issue while the base PR is running tests or awaiting review. Use when you say /stackon <PR> <ISSUE> or want to stack work on top of an existing PR.
---

# stackon — stack work on a dependent issue atop an in-flight PR

Like `/skill:workon`, but instead of basing the new branch on the repo's
default branch, it bases it on **an existing PR's head branch**. This is
PR stacking: you keep building on issue B (which depends on issue A) while
A's PR is still in CI or review, without waiting for A to merge and without
cherry-picking A's commits into B's branch.

The new branch carries B's work; its parent in the stack is A's PR. When A
merges, B's branch rebases down onto main and becomes a normal PR.

## Command

- `stackon.sh [--dry-run] <PR#|URL> <ISSUE#|URL> [REPO]` — fetch both, create
  a stacked worktree.

Arguments:
- `<PR#|URL>` — **required.** The existing (base) PR to stack on top of: a
  number (`1390`) or a GitHub PR URL (`github.com/.../pull/1390`). Must be
  `OPEN`.
- `<ISSUE#|URL>` — **required.** The issue to work on: a number or a GitHub
  issue URL. Must be `OPEN`.
- `[REPO]` — optional `owner/name`. Defaults to the current directory's repo.
- `--dry-run` — print what would happen without creating anything.

## What it does

1. Normalizes both args (bare number or GitHub URL → number).
2. Fetches the PR via `gh pr view`; **aborts unless it's OPEN** (can't stack on
   a merged/closed PR — use `/skill:workon <issue>` to base on main instead).
3. Fetches the issue via `gh issue view`; aborts unless OPEN. Prints the body.
4. Derives a branch name `i<N>-<slug>` (ASCII kebab-case, total length
   capped — default 16), the same rule as workon; override with
   `PI_WORKON_MAX_NAME_LEN` (legacy `PI_STACKON_MAX_NAME_LEN` still honored).
5. If a worktree for that branch already exists, **reuses it** (prints the path).
6. Otherwise fetches the PR's head via `git fetch origin refs/pull/<PR>/head`
   (works for same-repo **and** fork PRs — GitHub serves every PR head at that
   ref) and creates a worktree off that commit at
   `<repo_root>/.worktrees/<branch>`, adding `.worktrees/` to
   `.git/info/exclude` (local-only; never touches `.gitignore`).
7. Prints a summary with `WORKTREE_PATH=`, `BRANCH=`, `BASE_PR_URL=`,
   `BASE_PR_HEAD=`, `ISSUE_URL=`, and the issue body.

The script does **not** change the caller's cwd (a subprocess can't). Run all
subsequent implementation commands inside the printed `WORKTREE_PATH`.

## Invocation

This skill registers as `/skill:stackon`. Examples:

- `/skill:stackon 1390 1422`
- `/skill:stackon https://github.com/mcdonc/klangk/pull/1390 1422`
- `/skill:stackon 1390 https://github.com/mcdonc/klangk/issues/1422`

## Workflow

When you run `/skill:stackon <PR> <ISSUE> [repo]` (or ask equivalently):

1. Run the script:
   ```bash
   <skill_dir>/scripts/stackon.sh <PR> <ISSUE> [REPO]
   ```
   The skill directory is the one containing this `SKILL.md`, e.g.
   `~/.pi/agent/skills/stackon`.

2. From the output, capture the machine-readable lines:
   - `WORKTREE_PATH=<path>` — where to work.
   - `BRANCH=<branch>` — the new stacked branch.
   - `BASE_PR_URL=<url>` / `BASE_PR_HEAD=<branch>` — the parent PR.
   - `ISSUE_URL=<url>` — the issue permalink.

3. **Switch context to the worktree**: run all subsequent commands (edits,
   builds, tests, commits) inside `WORKTREE_PATH`.

4. **Implement the issue**: read the printed issue body, break it into steps,
   make changes, run tests, commit incrementally on the new branch.

5. **Open the stacked PR targeting the parent's branch** (not main), so GitHub
   renders the stack:
   ```bash
   gh pr create --base <BASE_PR_HEAD> --head <BRANCH> --title "..." --body-file <body>
   ```

6. **Review, gate, and post the structural artifacts.** Run the
   same loop workon defines: the repo's pre-flight gate before the
   first commit attempt (workon step 6), the fresh-eyes review plus
   one delta round with the review posted as a PR comment (workon
   steps 8–9), and — once the review rounds are done — the
   component-level structure record. Anchor the delta at the parent
   PR's head, not main: a merge base against main would fold in the
   base PR's own changes and flood the report.
   ```bash
   git fetch origin "refs/pull/<BASE_PR#>/head"
   "$HOME/.pi/agent/skills/workon/scripts/structure_artifacts.py" \
     --base FETCH_HEAD --tree HEAD > /tmp/structure.md
   cat /tmp/structure.md   # "No component-level structural changes" -> skip posting
   gh pr comment <PR#> --body-file /tmp/structure.md
   ```
   Prefer a repo-shipped `scripts/structure_artifacts.py` when the
   repo defines one, and commit before running — the generator
   reads git trees. It lives in the workon skill's `scripts/`
   directory; both skills share it.

7. **When the base PR merges**, the stack collapses: rebase this branch onto
   the default branch and re-target its PR at main:
   ```bash
   git fetch origin <default-branch>
   git rebase origin/<default-branch>
   git push --force-with-lease
   gh pr edit <this PR#> --base <default-branch>
   ```
   Re-run the suite after the rebase.

## Notes

- Stacking works for **fork PRs** too — the base is fetched from
  `refs/pull/<PR>/head`, which GitHub serves for every PR regardless of which
  fork owns the head branch.
- The new branch is based on a **commit** (the PR head at stackon time), not a
  tracking branch. If the base PR is force-pushed while you work, re-sync by
  re-running the fetch and rebasing onto the new head.
- If the base PR is already `MERGED` or `CLOSED`, the script refuses and points
  you at `/skill:workon` (base on main) — there's nothing to stack on.
- Worktrees live at `<repo_root>/.worktrees/<branch>` and are git-excluded via
  `.git/info/exclude` (no `.gitignore` change).
