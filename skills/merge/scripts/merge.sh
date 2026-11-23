#!/usr/bin/env bash
# merge.sh — merge a PR with --admin (bypassing merge protection) and clean up,
# stacked-PR safe: retargets open children before deleting the branch and
# replays each child's own commits after a history-rewriting merge.
#
# Usage: merge.sh [--dry-run] [--no-rebase] [--expect-base <BRANCH>] <PR#> [REPO]
#   --dry-run      Print what would happen; do not merge or delete anything.
#   --no-rebase    Retarget stacked children but never auto-rebase them;
#                  print the exact manual rebase commands instead.
#   --expect-base  Safety guard: abort unless the PR's base branch is <BRANCH>.
#                  Use for integration-branch workflows (workon --base X) so a
#                  PR accidentally opened against the default branch cannot be
#                  --admin merged into it by this script.
#   PR#            required PR number
#   REPO           optional repo (owner/name); defaults to the current dir's repo
#
# Env:
#   MERGE_METHOD   squash|merge|rebase  (default: squash)
#
# Order of operations:
#   1. Detects stacked children — open PRs whose base branch is this PR's head
#      branch — and records the head tip SHA (the boundary for a child's "own
#      commits"; a squash creates brand-new SHAs, so the merge-base goes stale).
#   2. Merges the PR via `gh pr merge --admin --<method>` (server-side; no
#      --delete-branch so it works even if the branch is checked out in a worktree).
#   3. Confirms the PR is MERGED. If the merge did not succeed, ABORT — nothing
#      is deleted and children are untouched.
#   4. Retargets each child to this PR's base branch BEFORE any branch deletion.
#      Deleting the head branch first would flip children onto the default
#      branch (where they lack the parent's changes and conflict) — or close
#      them outright — and a closed PR can no longer be retargeted at all.
#   5. After a squash/rebase merge each child still carries the parent's
#      original commits, so it is CONFLICTING against the new base. The script
#      replays only the child's own commits in a throwaway worktree —
#      `git rebase --onto <base tip> <parent pre-merge tip>` — force-pushes
#      with --force-with-lease, then waits for GitHub to recompute
#      mergeability. --no-rebase, fork children, and failed rebases fall back
#      to printing the exact manual commands. (MERGE_METHOD=merge keeps the
#      parent's real commits in the base, so no rebase is needed.)
#   6. Removes any git worktree whose checked-out branch is the PR's head
#      branch (skips the worktree containing the current dir).
#   7. Force-deletes the PR's local branch.
#   8. Deletes the PR's remote branch (same-repo PRs only; fork PRs are
#      skipped; also skipped when a child retarget failed, since deletion
#      would strand the children).
#
# If the PR is already MERGED, the merge step is skipped and child handling +
# cleanup run. If the PR is CLOSED (not merged) or the merge fails, the script
# aborts without deleting anything (use --dry-run to preview).
#
# Exit codes: 0 = clean; 1 = hard error (nothing merged or deleted);
#             2 = usage error; 3 = PR merged but a stacked child still needs
#             the manual steps printed above the summary.
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
NO_REBASE=0
EXPECT_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-rebase) NO_REBASE=1; shift ;;
    --expect-base)
      [ -n "${2:-}" ] || { echo "merge.sh: --expect-base requires a branch name" >&2; exit 2; }
      EXPECT_BASE="$2"; shift 2 ;;
    -*) echo "merge.sh: unknown option '$1'" >&2; exit 2 ;;
    *) break ;;
  esac
done

PR="${1:?usage: merge.sh [--dry-run] [--no-rebase] [--expect-base <BRANCH>] <PR#> [REPO]}"
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
# headRefOid is captured BEFORE the merge: it is the pre-squash parent tip,
# i.e. the boundary that separates a stacked child's own commits from the
# parent's (after a squash the merge-base is useless — new SHAs, no ancestry).
PRINFO="$("${GH[@]}" pr view "$PR" --json number,state,headRefName,baseRefName,headRefOid,headRepository 2>/dev/null)"
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

read -r BRANCH BASE_REF HEAD_REPO STATE PARENT_TIP <<EOF
$(printf '%s' "$PRINFO" | python3 -c '
import json, sys
d = json.load(sys.stdin)
hr = (d.get("headRepository") or {}).get("nameWithOwner","")
print(d.get("headRefName",""), d.get("baseRefName",""), hr, d.get("state",""), d.get("headRefOid") or "")
')
EOF

IS_FORK=0
[ -n "$HEAD_REPO" ] && [ -n "$BASE_REPO" ] && [ "$HEAD_REPO" != "$BASE_REPO" ] && IS_FORK=1

echo "PR #$PR  branch='$BRANCH'  base='$BASE_REF'  state=$STATE  $([ "$IS_FORK" = 1 ] && echo "[fork: $HEAD_REPO -> $BASE_REPO]" || echo "[same-repo: $BASE_REPO]")"
[ "$DRY_RUN" = 1 ] && echo "(dry-run: no changes will be made)"

# --- Base-branch guard (--expect-base) ---
# The merge lands the PR into its base branch. When the caller names the
# expected base, refuse anything else — --admin bypasses branch protection,
# so this guard is the one thing standing between a wrong-base PR and the
# default branch.
if [ -n "$EXPECT_BASE" ] && [ "$BASE_REF" != "$EXPECT_BASE" ]; then
  echo "merge.sh: PR #$PR base branch is '$BASE_REF', expected '$EXPECT_BASE'." >&2
  echo "merge.sh: refusing to merge — a PR with the wrong base would land in the wrong branch." >&2
  exit 1
fi

# --- Stacked children: open PRs whose base branch is this PR's head branch ---
# Detected (and their head tips recorded) BEFORE anything happens. Children of
# a fork parent can still be retargeted (the base branch lives in this repo).
declare -a CHILD_NUMS=()
declare -A CHILD_HEAD=() CHILD_REPO=() CHILD_OK=()
if [ "$BRANCH" != "$BASE_REF" ]; then
  while IFS= read -r cnum; do
    [ -n "$cnum" ] || continue
    CHILD_NUMS+=("$cnum")
    cline="$("${GH[@]}" pr view "$cnum" --json headRefName,headRepository 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
hr = (d.get("headRepository") or {}).get("nameWithOwner", "")
print((d.get("headRefName") or "") + "\t" + hr)
' 2>/dev/null || true)"
    CHILD_HEAD[$cnum]="$(printf '%s' "$cline" | cut -f1)"
    CHILD_REPO[$cnum]="$(printf '%s' "$cline" | cut -f2)"
    CHILD_OK[$cnum]=0
  done < <("${GH[@]}" pr list --state open --limit 200 --json number,baseRefName \
    | BRANCH="$BRANCH" python3 -c '
import json, os, sys
want = os.environ.get("BRANCH", "")
for pr in json.load(sys.stdin):
    if pr.get("baseRefName") == want:
        print(pr.get("number", ""))
')
fi

# --- Child plan (always printed — the boundary SHA lands in the transcript, ---
# --- so an interrupted run can still be finished by hand)                  ---
if [ ${#CHILD_NUMS[@]} -gt 0 ]; then
  echo "Stacked children detected (open PRs based on '$BRANCH'): ${CHILD_NUMS[*]}"
  for c in "${CHILD_NUMS[@]}"; do
    cfork=0
    [ -n "${CHILD_REPO[$c]}" ] && [ "${CHILD_REPO[$c]}" != "$BASE_REPO" ] && cfork=1
    echo "  child #$c head='${CHILD_HEAD[$c]}' -> retarget to '$BASE_REF' before branch deletion"
    if [ "$METHOD" = "squash" ] || [ "$METHOD" = "rebase" ]; then
      if [ "$NO_REBASE" = 1 ]; then
        echo "  child #$c: --no-rebase — exact manual rebase commands will be printed"
      elif [ "$cfork" = 1 ]; then
        echo "  child #$c: fork PR — cannot auto-rebase; manual commands will be printed"
      else
        echo "  child #$c: after merge, replay own commits: git rebase --onto 'refs/remotes/origin/$BASE_REF' '$PARENT_TIP' (boundary = pre-merge parent tip)"
      fi
    fi
  done
fi

# --- Default branch (to switch off the PR branch if we're on it) ---
DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^origin/@@' 2>/dev/null)"
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="$("${GH[@]}" repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo "")"

# --- Step 1: Merge (or confirm already merged) ---
# Only proceed to cleanup if the PR ends up MERGED.
if [ "$STATE" = "MERGED" ]; then
  echo "PR is already MERGED — skipping merge, running child handling + cleanup."
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
    echo "  (merge succeeded despite non-zero exit; continuing)"
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

# === Below here the PR is confirmed MERGED (or dry-run previewing it) ===

declare -a CHILD_SUMMARY=() CHILD_MANUAL=()
CHILD_RETARGET_FAILED=0

# manual_rebase <pr> <head> — echo the exact recovery commands for a child
# whose own commits must be replayed by hand.
manual_rebase() {
  local c="$1" head="$2"
  local tip="$PARENT_TIP"
  [ -n "$tip" ] || tip="\$(gh pr view $PR --json headRefOid -q .headRefOid)  # parent pre-merge tip"
  cat <<EOF
  # Replay child PR #$c ('$head') own commits onto '$BASE_REF' by hand
  # (in a worktree — the main checkout may hold uncommitted work):
  git fetch origin '+refs/heads/$head:refs/remotes/origin/$head' '+refs/heads/$BASE_REF:refs/remotes/origin/$BASE_REF'
  git worktree add --detach "/tmp/rebase-$head" 'refs/remotes/origin/$head'
  git -C "/tmp/rebase-$head" rebase --onto 'refs/remotes/origin/$BASE_REF' '$tip'
  git -C "/tmp/rebase-$head" push --force-with-lease="refs/heads/$head" origin 'HEAD:refs/heads/$head'
  git worktree remove --force "/tmp/rebase-$head"
  # then wait for mergeability before merging #$c:
  ${GH[*]} pr view $c --json mergeable,mergeStateStatus
EOF
}

# rebase_child <pr> <head> — replay the child's own commits (parent-tip..head)
# onto the new base tip in a throwaway worktree; force-push with a lease;
# poll GitHub until mergeability is recomputed. Returns 0 on success.
rebase_child() {
  local c="$1" head="$2"
  local tmp wt oid m mg ms
  if [ -z "$PARENT_TIP" ]; then
    echo "  (no parent tip SHA recorded — cannot isolate child #$c own commits)"
    return 1
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/merge-child.XXXXXX" 2>/dev/null)" || return 1
  wt="$tmp/wt"
  if ! git fetch -q origin "+refs/heads/$head:refs/remotes/origin/$head" "+refs/heads/$BASE_REF:refs/remotes/origin/$BASE_REF"; then
    rm -rf "$tmp"; echo "  (failed to fetch '$head' / '$BASE_REF')"; return 1
  fi
  oid="$(git rev-parse --verify -q "refs/remotes/origin/$head" || true)"
  if [ -z "$oid" ]; then
    rm -rf "$tmp"; echo "  (remote branch '$head' not found)"; return 1
  fi
  if [ "$oid" = "$PARENT_TIP" ]; then
    rm -rf "$tmp"
    echo "  child #$c head == parent tip (no commits of its own) — skipping rebase"
    CHILD_SUMMARY+=("child PR #$c: no own commits; nothing to rebase")
    return 0
  fi
  if ! git worktree add --detach "$wt" "refs/remotes/origin/$head" >/dev/null 2>&1; then
    rm -rf "$tmp"; echo "  (could not create throwaway worktree for '$head')"; return 1
  fi
  if git -C "$wt" rebase --onto "refs/remotes/origin/$BASE_REF" "$PARENT_TIP" >/dev/null 2>&1; then
    if git -C "$wt" push --force-with-lease="refs/heads/$head:$oid" origin "HEAD:refs/heads/$head" >/dev/null 2>&1; then
      git worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$tmp"
      echo "  rebased #$c onto 'origin/$BASE_REF' (own commits only) and force-pushed ✓"
      echo "  waiting for GitHub to recompute PR #$c mergeability (up to ~2 min)..."
      # The API can serve a stale cached CONFLICTING right after the push, so
      # MERGEABLE is trusted immediately but CONFLICTING only after it is seen
      # twice in a row (5 s apart).
      mg=""; ms=""; confl=""
      for _ in $(seq 1 24); do
        sleep 5
        m="$("${GH[@]}" pr view "$c" --json mergeable,mergeStateStatus 2>/dev/null \
          | python3 -c 'import json,sys
d = json.load(sys.stdin)
print((d.get("mergeable") or ""), (d.get("mergeStateStatus") or ""))' 2>/dev/null || true)"
        read -r mg ms <<<"$m"
        case "$mg" in
          MERGEABLE) break ;;
          CONFLICTING)
            [ -n "$confl" ] && break
            confl=1 ;;
          *) confl="" ;;
        esac
      done
      if [ "$mg" = "MERGEABLE" ]; then
        CHILD_SUMMARY+=("child PR #$c ('${CHILD_HEAD[$c]}'): retargeted to '$BASE_REF' ✓ rebased + pushed ✓ mergeable ✓ (state: ${ms:-unknown})")
        return 0
      elif [ "$mg" = "CONFLICTING" ]; then
        echo "  PR #$c is still CONFLICTING after the rebase — needs manual attention." >&2
        return 1
      else
        CHILD_SUMMARY+=("child PR #$c ('${CHILD_HEAD[$c]}'): retargeted + rebased + pushed ✓; mergeability still '${mg:-unknown}' after ~2 min — re-check with: gh pr view $c --json mergeable,mergeStateStatus")
        return 0
      fi
    else
      git worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$tmp"
      echo "  (force-push of rebased '$head' failed)" >&2
      return 1
    fi
  else
    git -C "$wt" rebase --abort >/dev/null 2>&1
    git worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$tmp"
    echo "  (rebase of '$head' hit conflicts — worktree cleaned up, branch untouched)" >&2
    return 1
  fi
}

# --- Step 2: Retarget children to this PR's base, BEFORE any branch deletion ---
# Retargeting only works while the child is open; branch deletion without it
# flips children onto the default branch (or closes them outright).
if [ ${#CHILD_NUMS[@]} -gt 0 ] && [ "$DRY_RUN" = 0 ]; then
  for c in "${CHILD_NUMS[@]}"; do
    if "${GH[@]}" pr edit "$c" --base "$BASE_REF" >/dev/null 2>&1; then
      newbase="$("${GH[@]}" pr view "$c" --json baseRefName -q .baseRefName 2>/dev/null)"
      if [ "$newbase" = "$BASE_REF" ]; then
        CHILD_OK[$c]=1
        echo "Retargeted child PR #$c ('${CHILD_HEAD[$c]}'): base '$BRANCH' -> '$BASE_REF' ✓"
      else
        echo "merge.sh: WARNING — retarget of child PR #$c did not stick (base is now '$newbase')." >&2
        CHILD_RETARGET_FAILED=1
        CHILD_MANUAL+=("child PR #$c: retarget did not stick — run: ${GH[*]} pr edit $c --base '$BASE_REF'")
      fi
    else
      echo "merge.sh: WARNING — failed to retarget child PR #$c to '$BASE_REF'." >&2
      CHILD_RETARGET_FAILED=1
      CHILD_MANUAL+=("child PR #$c: retarget failed — recover with:")
      CHILD_MANUAL+=("  ${GH[*]} pr edit $c --base '$BASE_REF'")
      CHILD_MANUAL+=("  (if #$c was closed by an earlier base-branch deletion, recreate the branch first:)")
      CHILD_MANUAL+=("   git fetch origin '$BASE_REF' && git push origin 'origin/$BASE_REF:refs/heads/$BRANCH'")
      CHILD_MANUAL+=("   ${GH[*]} pr reopen $c && ${GH[*]} pr edit $c --base '$BASE_REF' && git push origin --delete '$BRANCH'")
    fi
  done
elif [ ${#CHILD_NUMS[@]} -gt 0 ] && [ "$DRY_RUN" = 1 ]; then
  for c in "${CHILD_NUMS[@]}"; do
    echo "[dry-run] would retarget child PR #$c ('${CHILD_HEAD[$c]}') to base '$BASE_REF' before branch deletion"
  done
fi

# --- Step 3: Fix the squash-stack conflict (squash/rebase methods only) ---
# After a squash the base contains new SHAs and the child still carries the
# parent's originals, so the child is CONFLICTING against the new base.
# --admin bypasses reviews and checks but NOT conflicts — the child must be
# rebased before it can merge. A merge-commit method keeps the parent's real
# commits (ancestry intact), so no rebase is needed there.
if [ ${#CHILD_NUMS[@]} -gt 0 ] && [ "$DRY_RUN" = 0 ] && { [ "$METHOD" = "squash" ] || [ "$METHOD" = "rebase" ]; }; then
  for c in "${CHILD_NUMS[@]}"; do
    [ "${CHILD_OK[$c]}" = 1 ] || continue
    cfork=0
    [ -n "${CHILD_REPO[$c]}" ] && [ "${CHILD_REPO[$c]}" != "$BASE_REPO" ] && cfork=1
    if [ "$cfork" = 1 ]; then
      CHILD_MANUAL+=("child PR #$c is a fork PR — cannot auto-rebase from here (run in a checkout with push access to the fork):")
      while IFS= read -r ml; do CHILD_MANUAL+=("  $ml"); done < <(manual_rebase "$c" "${CHILD_HEAD[$c]}")
    elif [ "$NO_REBASE" = 1 ]; then
      CHILD_MANUAL+=("child PR #$c: --no-rebase — replay its own commits by hand:")
      while IFS= read -r ml; do CHILD_MANUAL+=("  $ml"); done < <(manual_rebase "$c" "${CHILD_HEAD[$c]}")
    else
      if ! rebase_child "$c" "${CHILD_HEAD[$c]}"; then
        CHILD_MANUAL+=("child PR #$c ('${CHILD_HEAD[$c]}') needs a manual stacked rebase:")
        while IFS= read -r ml; do CHILD_MANUAL+=("  $ml"); done < <(manual_rebase "$c" "${CHILD_HEAD[$c]}")
      fi
    fi
  done
fi

# --- Step 4: Remove worktrees checking out the PR branch (skip current dir's worktree) ---
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

# --- Step 5: Delete local branch (force) if still present ---
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

# --- Step 6: Delete remote branch (same-repo only; not while children are stranded) ---
if [ "$IS_FORK" = 1 ]; then
  echo "PR is from a fork ($HEAD_REPO) — skipping remote branch deletion."
elif [ "$CHILD_RETARGET_FAILED" = 1 ]; then
  echo "Keeping remote branch '$BRANCH' — a child retarget failed; deleting the base branch"
  echo "now would flip the still-open children onto the default branch or close them."
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
echo "PR #$PR  branch='$BRANCH'  -> merged ✓  base='$BASE_REF'$([ "$DRY_RUN" = 1 ] && echo "  [DRY-RUN: nothing actually changed]")"
for line in "${CHILD_SUMMARY[@]}"; do
  echo "  $line"
done
if [ ${#CHILD_MANUAL[@]} -gt 0 ]; then
  echo
  echo "MANUAL STEPS REQUIRED:"
  for line in "${CHILD_MANUAL[@]}"; do
    echo "$line"
  done
fi
echo "Done."

[ ${#CHILD_MANUAL[@]} -gt 0 ] && exit 3
exit 0
