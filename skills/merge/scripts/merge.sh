#!/usr/bin/env bash
# merge.sh — merge a PR with --admin (bypassing merge protection) and clean up.
#
# Usage: merge.sh [--dry-run] <PR#> [REPO]
#   --dry-run   Print what would happen; do not merge or delete anything.
#   PR#         required PR number
#   REPO        optional repo (owner/name); defaults to the current dir's repo
#
# Env:
#   MERGE_METHOD   squash|merge|rebase  (default: squash)
#
# Order of operations:
#   1. Merges the PR via `gh pr merge --admin --<method>` (server-side; no --delete-branch
#      so it works even if the branch is checked out in a worktree).
#   2. Confirms the PR is MERGED. If the merge did not succeed, ABORT — nothing is deleted.
#   3. Removes any git worktree whose checked-out branch is the PR's head branch
#      (skips the worktree containing the current dir).
#   4. Force-deletes the PR's local branch.
#   5. Deletes the PR's remote branch (same-repo PRs only; fork PRs are skipped).
#
# If the PR is already MERGED, the merge step is skipped and cleanup runs.
# If the PR is CLOSED (not merged) or OPEN but the merge fails, the script aborts
# without deleting anything (use --dry-run to preview).
set -uo pipefail

# Re-exec inside `devenv shell` when the repo uses devenv.  This repo's git
# hooks (prek / pre-commit) and their tools (dart, ruff, ...) live in the
# devenv environment, not on the default PATH, so git commands that trigger
# hooks (e.g. `git push --delete`) must run there or the hooks error out /
# can't find their config.  Worktrees check out devenv.nix alongside the
# rest of the repo, so show-toplevel finds it from the main checkout or a
# worktree.  IN_DEVENV guards against re-exec loops.
REPO_ROOT_DETECTED="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if [ -f "$REPO_ROOT_DETECTED/devenv.nix" ] && [ -z "${IN_DEVENV:-}" ]; then
  export IN_DEVENV=1
  exec devenv shell -- bash "$0" "$@"
fi

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

PR="${1:?usage: merge.sh [--dry-run] <PR#> [REPO]}"
REPO="${2:-}"
METHOD="${MERGE_METHOD:-squash}"

case "$METHOD" in
  squash|merge|rebase) ;;
  *) echo "merge.sh: invalid MERGE_METHOD '$METHOD' (use squash|merge|rebase)" >&2; exit 2 ;;
esac

run() { # run <description> <command...>
  local desc="$1"; shift
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] $desc :: $*"
  else
    echo "$desc"
    "$@"
  fi
}

# gh invocation (with optional --repo)
if [ -n "$REPO" ]; then GH=(gh --repo "$REPO"); else GH=(gh); fi

# --- Fetch PR info ---
# Note: `baseRepository` is NOT a valid `gh pr view --json` field, so the base
# repo is resolved separately via `gh repo view` (or taken from the REPO arg).
PRINFO="$("${GH[@]}" pr view "$PR" --json number,state,headRefName,headRepository 2>/dev/null)"
if [ -z "$PRINFO" ]; then
  echo "merge.sh: could not fetch PR #$PR (wrong number? not in a repo? gh auth?)" >&2
  exit 1
fi

# Base repo: explicit arg, else the current repo's nameWithOwner.
if [ -n "$REPO" ]; then
  BASE_REPO="$REPO"
else
  BASE_REPO="$("${GH[@]}" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
fi

read -r BRANCH HEAD_REPO STATE <<EOF
$(printf '%s' "$PRINFO" | python3 -c '
import json, sys
d = json.load(sys.stdin)
hr = (d.get("headRepository") or {}).get("nameWithOwner","")
print(d.get("headRefName",""), hr, d.get("state",""))
')
EOF

IS_FORK=0
[ -n "$HEAD_REPO" ] && [ -n "$BASE_REPO" ] && [ "$HEAD_REPO" != "$BASE_REPO" ] && IS_FORK=1

echo "PR #$PR  branch='$BRANCH'  state=$STATE  $([ "$IS_FORK" = 1 ] && echo "[fork: $HEAD_REPO -> $BASE_REPO]" || echo "[same-repo: $BASE_REPO]")"
[ "$DRY_RUN" = 1 ] && echo "(dry-run: no changes will be made)"

# --- Default branch (to switch off the PR branch if we're on it) ---
DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^origin/@@' 2>/dev/null)"
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="$("${GH[@]}" repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo "")"

# --- Step 1: Merge (or confirm already merged) ---
# Only proceed to cleanup if the PR ends up MERGED.
if [ "$STATE" = "MERGED" ]; then
  echo "PR is already MERGED — skipping merge, running cleanup."
elif [ "$STATE" = "OPEN" ]; then
  # If currently on the PR branch, switch off so the local branch can be deleted later.
  if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" = "$BRANCH" ] && [ "$DRY_RUN" = 0 ]; then
    echo "Currently on '$BRANCH'; switching to '$DEFAULT_BRANCH'..."
    git checkout "$DEFAULT_BRANCH" >/dev/null 2>&1 || echo "  (warning: could not checkout $DEFAULT_BRANCH)"
  fi
  if ! run "Merging PR #$PR (--admin --$METHOD)" "${GH[@]}" pr merge "$PR" --admin --"$METHOD"; then
    rc=$?
    # Recheck: the merge may have succeeded despite a non-zero exit (rare).
    NEWSTATE="$("${GH[@]}" pr view "$PR" --json state 2>/dev/null \
      | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state",""))' 2>/dev/null)"
    if [ "$NEWSTATE" != "MERGED" ]; then
      echo "merge.sh: gh pr merge failed (exit $rc); state=$NEWSTATE. Aborting — nothing was deleted." >&2
      exit 1
    fi
    echo "  (merge succeeded despite non-zero exit; continuing cleanup)"
  fi
  # Confirm merged before any destructive cleanup (skip in dry-run, where no merge ran).
  if [ "$DRY_RUN" = 0 ]; then
    STATE="$("${GH[@]}" pr view "$PR" --json state 2>/dev/null \
      | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state",""))' 2>/dev/null)"
    if [ "$STATE" != "MERGED" ]; then
      echo "merge.sh: PR is not MERGED (state=$STATE) after merge attempt. Aborting — nothing was deleted." >&2
      exit 1
    fi
  else
    STATE="MERGED"  # assume success for preview
  fi
else
  # CLOSED (not merged), or any other state.
  echo "merge.sh: PR state is $STATE (not OPEN, not MERGED). Refusing to merge or delete." >&2
  echo "  Reopen the PR first, or run cleanup manually if you know the branches are safe to remove." >&2
  exit 1
fi

# === Cleanup below only runs when the PR is confirmed MERGED (or dry-run previewing it) ===

# --- Step 2: Remove worktrees checking out the PR branch (skip current dir's worktree) ---
mapfile -t WT_PAIRS < <(git worktree list --porcelain 2>/dev/null | python3 -c '
import sys
path = branch = None
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("worktree "):
        path = line[len("worktree "):]
        branch = ""
    elif line.startswith("branch "):
        branch = line[len("branch "):].replace("refs/heads/", "")
    elif line.strip() == "" and path:
        print(f"{path}\t{branch}")
        path = branch = None
if path:
    print(f"{path}\t{branch}")
')

for pair in "${WT_PAIRS[@]}"; do
  wt_path="${pair%%$'\t'*}"
  wt_branch="${pair##*$'\t'}"
  [ "$wt_branch" = "$BRANCH" ] || continue
  case "$PWD" in
    "$wt_path"|"$wt_path"/*)
      echo "Worktree for '$BRANCH' is the current dir ($wt_path) — skipping removal."
      ;;
    *)
      run "Removing worktree: $wt_path (branch $wt_branch)" git worktree remove --force "$wt_path"
      ;;
  esac
done

# --- Step 3: Delete local branch (force) if still present ---
if [ "$DRY_RUN" = 1 ]; then
  if git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
    echo "[dry-run] would delete local branch '$BRANCH'"
  else
    echo "[dry-run] local branch '$BRANCH' already absent"
  fi
elif git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
  echo "Deleting local branch '$BRANCH'..."
  git branch -D "$BRANCH" 2>&1 || echo "  (could not delete local branch)"
else
  echo "Local branch '$BRANCH' already absent."
fi

# --- Step 4: Delete remote branch (same-repo only) ---
if [ "$IS_FORK" = 1 ]; then
  echo "PR is from a fork ($HEAD_REPO) — skipping remote branch deletion."
else
  REMOTE="origin"
  if [ "$DRY_RUN" = 1 ]; then
    if git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
      echo "[dry-run] would delete remote branch '$BRANCH' on $REMOTE"
    else
      echo "[dry-run] remote branch '$BRANCH' already absent on $REMOTE"
    fi
  elif git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
    echo "Deleting remote branch '$BRANCH' on $REMOTE..."
    git push "$REMOTE" --delete "$BRANCH" 2>&1 || echo "  (failed to delete remote branch)"
  else
    echo "Remote branch '$BRANCH' already absent on $REMOTE."
  fi
fi

echo
echo "=== Summary ==="
echo "PR #$PR  branch='$BRANCH'  -> merged ✓$([ "$DRY_RUN" = 1 ] && echo "  [DRY-RUN: nothing actually changed]")"
echo "Done."
