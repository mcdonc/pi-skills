---
name: merge
description: Merge a GitHub PR with --admin (bypassing merge protection) and clean up, stacked-PR safe. Retargets open child PRs to the merged PR's base before deleting the branch, replays each child's own commits after a squash, then removes the worktree and local/remote branches. Use when the user says /merge <PR#>.
---

# Merge skill

Merge a pull request using admin override, then clean up all local and remote
artifacts in one shot — without breaking PRs stacked on it (`/stackon` output).

## Command

- `merge.sh [--dry-run] [--no-rebase] [--expect-base <BRANCH>] <PR#> [REPO]` — merge + stacked-child handling + cleanup.

Arguments:
- `--dry-run` — optional; print what would happen without merging or deleting anything.
- `--no-rebase` — optional; retarget stacked children but never auto-rebase
  them; print the exact manual `rebase --onto` + force-push commands instead.
- `--expect-base <BRANCH>` — optional; abort unless the PR's base branch is
  `<BRANCH>`. Use it for integration-branch workflows (`/workon --base X`):
  the script merges with `--admin`, which bypasses branch protection, so this
  guard is what stops a PR accidentally opened against the default branch
  from being merged into it. Children are retargeted to the PR's base, so in
  a stack every level ends up validated against the same expected base.
- `<PR#>` — required PR number.
- `[REPO]` — optional repo as `owner/name`. Defaults to the current directory's
  repo (detected via gh).

Env vars (optional):
- `MERGE_METHOD` — `squash` (default), `merge`, or `rebase`.

Exit codes: `0` clean; `1` hard error (nothing merged or deleted); `2` usage;
`3` the PR merged but a stacked child still needs the manual steps printed
above the summary (failed retarget/rebase, `--no-rebase`, or a fork child).

## What it does

1. Detects **stacked children** — open PRs whose base branch is this PR's head
   branch — and records the head tip SHA (the boundary for the children's "own
   commits"; a squash creates brand-new SHAs, so the merge-base goes stale).
2. Merges the PR via `gh pr merge <PR#> --admin --<method>` (bypasses merge
   protection). Server-side; does not touch local worktrees.
3. Confirms the PR is `MERGED`. If the merge did not succeed, **aborts — nothing
   is deleted and children are untouched**.
4. **Retargets each child to this PR's base** (`gh pr edit <child> --base …`)
   **before any branch deletion**. Deleting the head branch first flips
   children onto the *default* branch — where they lack the parent's changes —
   and GitHub closes them outright; a closed PR can no longer be retargeted.
   If a retarget fails, the merged branch is **not** deleted and the summary
   prints the recovery sequence (recreate branch → reopen → retarget →
   delete temp branch).
5. **Fixes the squash-stack conflict.** After a squash (or rebase-method)
   merge the child still carries the parent's original commits, so it is
   `CONFLICTING` against the new base — and `--admin` bypasses reviews and
   checks but *not* conflicts. The script replays only the child's own
   commits in a throwaway worktree — `git rebase --onto <base tip>
   <parent pre-merge tip>` — force-pushes with `--force-with-lease`, and waits
   for GitHub to recompute mergeability. `--no-rebase`, fork children, and
   failed rebases fall back to printing the exact manual commands (and exit
   `3`). `MERGE_METHOD=merge` keeps the parent's real commits in the base, so
   no rebase is needed there.
6. If currently on the PR branch, switches to the default branch so it can be deleted.
7. Removes any git worktree whose checked-out branch is the PR's head branch
   (skips the worktree containing the current directory).
8. Force-deletes the PR's local branch if it still exists.
9. Deletes the PR's remote branch (same-repo PRs only; fork PRs are skipped
   since the head branch lives on the fork; also skipped while a child
   retarget failed, since deletion would strand the children).

If the PR is already `MERGED`, the merge step is skipped and child handling +
cleanup run (safe to re-run). If the PR is `CLOSED` (not merged) or the merge
fails, the script aborts without deleting anything. Use `--dry-run` to preview.

## Invocation

This skill registers as `/skill:merge`. Example user requests:

- `/skill:merge 914`
- `/skill:merge 914 mcdonc/klangk`
- `merge PR 914` (the model maps this to the script)

**Merging a whole stack** (e.g. `/stackon` chains): run the script per PR,
bottom-up — `/skill:merge <A>`, then `/skill:merge <B>`, then `/skill:merge <C>`.
Each merge retargets and rebases its children, so by the time the next level
merges it is `MERGEABLE` against the base. Do not start at the top of the
stack (the top PR's base is its parent's branch, not the integration branch).

## Workflow

When the user runs `/skill:merge <PR#> [repo]` (or asks equivalently):

1. Run the script with the PR number (and optional repo):
   ```bash
   <skill_dir>/scripts/merge.sh <PR#> [REPO]
   ```
   For a PR that belongs to an integration-branch effort (`/workon --base X`),
   pass `--expect-base X` so the merge refuses a wrong-base PR.
2. Report the script's summary output to the user (merge status, base branch,
   child retarget/rebase outcomes, worktree removals, branch deletions).
3. If the exit code is `3`, surface the printed MANUAL STEPS to the user —
   the child PR needs its own commits replayed by hand before it can merge.
4. For a stack, repeat per level bottom-up.

## Notes

- The merge lands the PR into its **base branch**; the summary line prints it
  (`base='...'`). Check it matches the intended target before celebrating.
- `--admin` bypasses required reviews, status checks, and branch protection —
  but **not merge conflicts**; a `CONFLICTING` PR cannot merge at all, which
  is why the child rebase exists.
- The child "own commits" boundary is the **parent's pre-merge head tip**
  (printed in the child plan and in any manual instructions), *not* the
  merge-base with the base branch — after a squash the merge-base is stale.
  If a run is interrupted after the retarget, re-running no longer sees the
  child (its base already moved); finish it by hand with the printed boundary.
- The auto-rebase never touches the main checkout (it may hold uncommitted
  work) — it uses a throwaway detached worktree and pushes with
  `--force-with-lease` pinned to the exact pre-rebase OID.
- Mergeability polling: GitHub serves a stale cached `CONFLICTING` briefly
  after the force-push, so the script trusts `MERGEABLE` immediately but
  `CONFLICTING` only after two consecutive readings 5 s apart.
- **Closed-child rescue** (child already closed by a base-branch deletion):
  recreate the deleted branch at the integration tip, reopen, retarget, then
  delete the temp branch:
  ```bash
  git fetch origin <base>
  git push origin origin/<base>:refs/heads/<deleted-branch>
  gh pr reopen <child>
  gh pr edit <child> --base <base>
  git push origin --delete <deleted-branch>
  ```
  then replay the child's own commits (boundary = the parent's `headRefOid`,
  still queryable from the merged parent PR) as in the manual instructions.
- Fork PRs: remote branch deletion is skipped (the branch is on the
  contributor's fork, not your repo); fork *children* are retargeted but not
  auto-rebased (the push would target the fork) — their manual instructions
  must be run in a checkout with push access to the fork.
- If the current directory is itself the worktree for the PR branch, that worktree
  is not removed (can't delete the dir you're in) — run the skill from the main
  checkout or another worktree.
