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

2. From the script's output, capture the four machine-readable lines:
   - `WORKTREE_PATH=<path>` — where to work.
   - `BRANCH=<branch>` — the branch checked out there.
   - `BASE=<branch>` — the base branch the worktree was created from (the
     repo's default branch, or the `--base` value). Empty on a reused
     worktree that predates this field; recover it with
     `git -C <WORKTREE_PATH> config --get workon.base`.
   - `ISSUE_URL=<url>` — the issue permalink.

   The script also records the base as `workon.base` git config inside the
   worktree, so later sessions recover it without the original output.

3. **Switch context to the worktree**: run all subsequent implementation
   commands (edits, builds, tests, git commits) inside `WORKTREE_PATH`. Use
   `cd <WORKTREE_PATH>` for shell commands, or read/edit files using their
   absolute path under `WORKTREE_PATH`.

4. **Implement the issue**: read the printed issue body, break it into concrete
   steps, make code changes, run tests/linters, and commit incrementally on the
   new branch.

5. **Rebase onto the latest base branch before pushing.** The base branch
   (`BASE` from step 2 — the default branch, or the `--base` integration
   branch) may have moved since the worktree was created (other PRs merged —
   often via squash, which rewrites the base SHA with no ancestry link to the
   branch). A stale base shows up as spurious "conflicts" on PR creation even
   when there's no real divergence. Before the first push, and again whenever
   the PR sits open while other PRs land:
   ```bash
   base=$(git config --get workon.base)   # inside the worktree
   git fetch origin "$base"
   git rebase "origin/$base"
   # resolve any conflicts, then:
   git push -u origin HEAD --force-with-lease
   ```
   **Never rebase an integration-branch worktree onto the default branch** —
   rebase against the branch the worktree was based on (`workon.base`).
   Re-run the full test suite after the rebase to confirm the merge is clean.

6. **Run the repo's pre-flight gate before pushing.** If the repo defines
   a fast gate tool, run it and fix **everything** it names in one editing
   pass; re-run until green. In msks that is:
   ```bash
   devenv --quiet -O dotenv.enable:bool false shell -- msks-preflight
   ```
   It reports every commit-gate offender at once (lint, deferred imports,
   complexity, coverage gaps) and runs the gated suite when sources changed.
   Without it, the pre-commit hook surfaces offenders one at a time, and the
   adversarial review (step 8) burns its round on gate noise instead of
   design.

7. **Open the PR — with the matching base.** Once the rebase is clean and
   the suite passes, create the PR (`gh pr create` from the worktree) with a
   proper title and body — before any review runs, so the review can be
   posted on the PR. **Pass `--base <BASE>` whenever the worktree was
   created with `--base`**: `gh pr create` defaults the base to the repo's
   default branch, and a PR for integration-branch work opened without
   `--base` silently targets the default branch instead of the integration
   branch. A PR aimed at the wrong base squashes straight into the default
   branch at merge time.

8. **Review the branch — unless one has already been done.** Right after
   opening the PR, run the `/review` skill against the branch (the reviewer
   runs in the background and takes minutes — do changelog and other chores
   while it runs). Triage its findings, land fixes, and push them to the same
   branch; the open PR updates automatically. Skip the review only when one
   has already FINISHED on this branch's history (a completed review whose
   recorded head is an
   ancestor of — or equal to — the current HEAD; review records live under
   `~/.pi/agent/reviews/<owner>/<repo>/<branch>/<ts>/`). Only a run that
   finished **with a review** counts (`review-ok.sh`): a reviewer that hit the
   model's output token limit records `status=failed` beside an empty
   `review.md`, and that is not a review.
   ```bash
   wt=<WORKTREE_PATH>
   url=$(git -C "$wt" config --get remote.origin.url); url=${url%.git}; url=${url#*://}; url=${url#*:}
   slug="$(basename "$(dirname "$url")")/$(basename "$url")"
   branch=$(git -C "$wt" branch --show-current); head=$(git -C "$wt" rev-parse HEAD)
   bdir=${branch//\//-}   # review.sh records "a/b" as "a-b"
   reviewed=no
   for d in "$HOME/.pi/agent/reviews/$slug/$bdir"/*/; do
     "$HOME/.pi/agent/skills/review/scripts/review-ok.sh" "$d" || continue
     rh=$(grep -oP '^head=\K[0-9a-f]+' "$d/meta" 2>/dev/null)
     if [ -n "$rh" ] && git -C "$wt" merge-base --is-ancestor "$rh" "$head" 2>/dev/null; then reviewed=yes; break; fi
   done
   # reviewed=yes -> skip; reviewed=no -> run /review first
   ```
   The ancestor rule means post-review fix commits do not trigger another
   review (the reviewed base is contained in HEAD) — the footer's
   `rvw ✓ +N` is expected and fine. A genuinely unrelated new head still
   gets reviewed.

   **Round budget: one full review, one delta review, then merge.** Apply
   this mechanically from the review's structured sections — do not ask
   the user between rounds:
   - The full review (or a delta) finds **blocking or important** issues →
     fix, push, then automatically run exactly **one delta review** (see
     the review skill's *Delta reviews (round 2+)* section).
   - The delta comes back APPROVE, or with nits/questions only → stop
     reviewing. Post the review (step 9), wait for CI, and let the user
     merge. Nits never trigger a round.
   - The delta **still** finds blocking or important issues → stop anyway
     and surface them to the user. A third round means the PR needs the
     user, not another reviewer.
   - Merging is always the user's call (`/skill:merge`).

9. **Attach the review to the PR.** When the review has finished and its
   findings are addressed, post the reviewer's output as a
   PR comment so the review travels with the PR — reusing `$slug`/`$branch`
   from step 8, pick the newest run that finished with a review and post its
   text (`$bdir` as in step 8):
   ```bash
   pr=$(gh pr view --json number -q .number)   # from the worktree
   newest=""
   for d in "$HOME/.pi/agent/reviews/$slug/$bdir"/*/; do
     "$HOME/.pi/agent/skills/review/scripts/review-ok.sh" "$d" && newest="$d"
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

10. **Post the structural artifacts once the review rounds are done.**
    After the review flow settles — the delta review approves, or the
    full review finds nothing blocking — and the final fixes are
    pushed, attach the branch's component-level structure record to
    the PR: the import-edge delta, the public-API surface diff, and
    a Mermaid diagram of the touched components plus one hop of
    neighbors. Prefer a repo-shipped generator
    (`scripts/structure_artifacts.py` at the repo root) when the repo
    defines one; otherwise use the portable generator this skill
    ships (stdlib-only Python, reads both trees through git):
    ```bash
    wt=<WORKTREE_PATH>
    base=$(git -C "$wt" config --get workon.base)   # the PR's base branch
    "$HOME/.pi/agent/skills/workon/scripts/structure_artifacts.py" \
      --base "origin/$base" --tree HEAD > /tmp/structure.md
    cat /tmp/structure.md   # "No component-level structural changes" -> skip posting
    gh pr comment <PR#> --body-file /tmp/structure.md
    ```
    Commit first — the generator reads the committed tree, so
    uncommitted work is invisible to it. It runs last by design:
    every review round rewrites the branch, and after the final
    review the artifacts describe the tree that will actually
    merge. Use `--body-file <path>` exactly as shown — never
    `--body -` or `--body <(...)`.

    **Then post the 3D dependency graph as a gist.** The same tree
    data drives an interactive page: the module-level graph of the
    head tree rendered with `3d-force-graph`, where edges the branch
    adds glow green, edges it removes render red, and nodes are
    colored by component and sized by import count. The generator
    emits one self-contained HTML file (the library and the graph
    data are inlined), uploads it as a secret gist, and the PR
    comment links an in-browser rendering and the gist source:
    ```bash
    base=$(git -C "$wt" config --get workon.base)   # the PR's base branch
    "$HOME/.pi/agent/skills/workon/scripts/dep_graph_3d.py" \
      --base "origin/$base" --tree HEAD --out /tmp/dep-graph-3d.html
    gist=$(gh gist create /tmp/dep-graph-3d.html \
      --desc "<owner/repo>#<PR#> dependency graph (3D)")
    raw="${gist/gist.github.com/gist.githubusercontent.com}/raw/dep-graph-3d.html"
    {
      echo "## 3D dependency graph (self-contained HTML)"
      echo
      echo "- [Render in browser](https://htmlpreview.github.io/?$raw)"
      echo "- [Gist source]($gist)"
      echo
      echo "The page is fully self-contained: save it from either link and it opens offline. GitHub serves the raw gist as plain text, so the source link downloads; the render link views."
    } > /tmp/dep3d-comment.md
    gh pr comment <PR#> --body-file /tmp/dep3d-comment.md
    ```
    The first run of `dep_graph_3d.py` fetches the `3d-force-graph`
    bundle from a CDN into `~/.cache/pi-skills/` and inlines it from
    then on; pass `--lib <path>` to point at a specific copy. The
    render link routes the page through the third-party
    htmlpreview service, which can read anything the gist URL can —
    on a private repo, use the source link and open the file
    locally when that exposure matters. The gist is secret
    (unlisted): it stays out of search and your public profile.

11. When finished (PR merged), clean up with the `/skill:merge <PR#>` skill,
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
- **The PR is opened before the review runs.** Workflow steps 7–9: create the
  PR, review the branch, then post the review as a PR comment. Review records
  live under `~/.pi/agent/reviews/` — the same records the worktree-indicator
  footer's `rvw` segment reads. Post-review fixes are pushed to the same
  branch and update the open PR.
- Re-running the skill on the same issue reuses the existing worktree rather
  than clobbering it.
