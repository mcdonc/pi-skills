---
name: merge
description: Merge a GitHub PR with --admin (bypassing merge protection) and clean up. Deletes any worktree for the PR's branch, then removes the PR's branch locally and remotely. Use when the user says /merge <PR#>.
---

# Merge skill

Merge a GitHub pull request using admin override, then clean up all local and
remote artifacts in one shot.

## Command

- `merge.sh [--dry-run] <PR#> [REPO]` — merge + cleanup.

Arguments:
- `--dry-run` — optional; print what would happen without merging or deleting anything.
- `<PR#>` — required PR number.
- `[REPO]` — optional repo as `owner/name`. Defaults to the current directory's
  repo (detected via gh).

Env vars (optional):
- `MERGE_METHOD` — `squash` (default), `merge`, or `rebase`.

## What it does

1. Merges the PR via `gh pr merge <PR#> --admin --<method>` (bypasses merge
   protection). Server-side; does not touch local worktrees.
2. Confirms the PR is `MERGED`. If the merge did not succeed, **aborts — nothing
   is deleted**.
3. If currently on the PR branch, switches to the default branch so it can be deleted.
4. Removes any git worktree whose checked-out branch is the PR's head branch
   (skips the worktree containing the current directory).
5. Force-deletes the PR's local branch if it still exists.
6. Deletes the PR's remote branch (same-repo PRs only; fork PRs are skipped
   since the head branch lives on the fork and can't be removed from origin).

If the PR is already `MERGED`, the merge step is skipped and cleanup runs.
If the PR is `CLOSED` (not merged) or the merge fails, the script aborts without
deleting anything. Use `--dry-run` to preview safely.

## Invocation

This skill registers as `/skill:merge`. Example user requests:

- `/skill:merge 914`
- `/skill:merge 914 mcdonc/klangk`
- `merge PR 914` (the model maps this to the script)

## Workflow

When the user runs `/skill:merge <PR#> [repo]` (or asks equivalently):

1. Run the script with the PR number (and optional repo):
   ```bash
   <skill_dir>/scripts/merge.sh <PR#> [REPO]
   ```
2. Report the script's summary output to the user (merge status, worktree removals,
   branch deletions).

## Notes

- `--admin` bypasses required reviews, status checks, and branch protection. Only
  use for PRs you intend to force-merge.
- Fork PRs: remote branch deletion is skipped (the branch is on the contributor's
  fork, not your repo).
- If the current directory is itself the worktree for the PR branch, that worktree
  is not removed (can't delete the dir you're in) — run the skill from the main
  checkout or another worktree.
