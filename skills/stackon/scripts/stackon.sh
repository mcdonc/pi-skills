#!/usr/bin/env bash
# stackon.sh — stack work on a GitHub issue on top of an in-flight PR's branch.
#
# Usage: stackon.sh [--dry-run] <PR#|URL> <ISSUE#|URL> [REPO]
#   --dry-run   Print what would happen; create nothing.
#   PR          required: the existing (base) PR to stack on — number or URL.
#   ISSUE       required: the issue to work on — number or URL.
#   REPO        optional repo (owner/name); defaults to the cwd's repo.
#
# Like workon, but the new worktree/branch is based off the PR's head commit
# (origin's refs/pull/<PR>/head) instead of the default branch — so you can
# make progress on a dependent issue while the base PR runs tests or awaits
# review. Works for same-repo AND fork PRs: GitHub serves every PR's head at
# refs/pull/<N>/head regardless of which fork owns the branch.
#
# Branch/worktree naming: i<N>-<short-slug> with the *total* length capped
# (default 16), exactly as workon.sh names its branches — override with
# PI_WORKON_MAX_NAME_LEN (or legacy PI_STACKON_MAX_NAME_LEN).
#
# What it does:
#   1. Normalizes the PR + issue args (bare number or github URL → number).
#   2. Fetches the PR; aborts unless OPEN. Records its head branch.
#   3. Fetches the issue; aborts unless OPEN.
#   4. Derives branch i<N>-<slug> (same rule as workon; length-capped).
#   5. If a worktree for that branch exists, reuses it (prints the path).
#   6. Otherwise fetches refs/pull/<PR>/head and creates a worktree off that
#      commit at <repo_root>/.worktrees/<branch>, adding .worktrees/ to
#      .git/info/exclude (local-only; never touches .gitignore).
#   7. Prints a summary: base PR (branch/url/state), issue (title/url/body),
#      and the new worktree path/branch + stacking guidance.
#
# The script does NOT change the caller's cwd (it can't). The agent should run
# subsequent commands inside the printed WORKTREE_PATH.
set -uo pipefail

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*) echo "stackon.sh: unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

PR_RAW="${1:?usage: stackon.sh [--dry-run] <PR#|URL> <ISSUE#|URL> [REPO]}"
ISSUE_RAW="${2:?usage: stackon.sh [--dry-run] <PR#|URL> <ISSUE#|URL> [REPO]}"
REPO="${3:-}"

# --- Normalize PR / issue refs (bare number or github URL → number) -------
normalize_ref() {
  local input="$1" kind="$2"
  if [[ "$input" =~ ^[0-9]+$ ]]; then printf '%s' "$input"; return 0; fi
  local seg="${input##*/}"        # last path segment
  seg="${seg%%#*}"               # drop fragment
  seg="${seg%%\?*}"              # drop query
  if [[ "$seg" =~ ^[0-9]+$ ]]; then printf '%s' "$seg"; return 0; fi
  echo "stackon.sh: could not parse $kind reference: $input" >&2
  return 1
}
PR="$(normalize_ref "$PR_RAW" "PR")" || exit 1
ISSUE="$(normalize_ref "$ISSUE_RAW" "issue")" || exit 1

# Light sanity: flag obviously-swapped URL types (lenient — a bare number
# can't be checked this way, so only URLs are validated).
case "$PR_RAW" in
  */issues/*)
    echo "stackon.sh: '$PR_RAW' looks like an issue URL, but the first arg must be a PR." >&2
    exit 2 ;;
esac
case "$ISSUE_RAW" in
  */pull/*)
    echo "stackon.sh: '$ISSUE_RAW' looks like a PR URL, but the second arg must be an issue." >&2
    exit 2 ;;
esac

# gh invocation (with optional --repo)
if [ -n "$REPO" ]; then GH=(gh --repo "$REPO"); else GH=(gh); fi

# Must be inside a git repo (the worktree is created here).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "stackon.sh: not inside a git repository." >&2
  exit 1
}

# --- Fetch PR info -------------------------------------------------------
PR_JSON="$("${GH[@]}" pr view "$PR" --json number,title,state,headRefName,url,baseRefName 2>/dev/null)" || {
  echo "stackon.sh: could not fetch PR #$PR (wrong number? gh auth? not in this repo?)" >&2
  exit 1
}
IFS=$'\x1f' read -r PR_NUM PR_TITLE PR_STATE PR_HEAD PR_URL PR_BASE < <(
  printf '%s' "$PR_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
US = "\x1f"
sys.stdout.write(US.join([
    str(d.get("number", "")),
    d.get("title", ""),
    d.get("state", ""),
    d.get("headRefName", ""),
    d.get("url", ""),
    d.get("baseRefName", ""),
]))
'
)
echo "Base PR #$PR_NUM: $PR_TITLE"
echo "  state=$PR_STATE  head=$PR_HEAD  base=$PR_BASE  url=$PR_URL"
[ "$DRY_RUN" = 1 ] && echo "(dry-run: nothing will be created)"

if [ "$PR_STATE" != "OPEN" ]; then
  echo "stackon.sh: base PR #$PR is $PR_STATE, not OPEN — there's nothing to stack on." >&2
  echo "  If it already merged, base on the default branch instead: /skill:workon $ISSUE_RAW" >&2
  exit 1
fi

# --- Fetch issue info ----------------------------------------------------
ISSUE_JSON="$("${GH[@]}" issue view "$ISSUE" --json number,title,state,url,body 2>/dev/null)" || {
  echo "stackon.sh: could not fetch issue #$ISSUE (wrong number? gh auth?)" >&2
  exit 1
}
IFS=$'\x1f' read -r I_NUM I_TITLE I_STATE I_URL I_BODY < <(
  printf '%s' "$ISSUE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
US = "\x1f"
sys.stdout.write(US.join([
    str(d.get("number", "")),
    d.get("title", ""),
    d.get("state", ""),
    d.get("url", ""),
    d.get("body", "") or "",
]))
'
)
echo "Issue #$I_NUM: $I_TITLE"
echo "  state=$I_STATE  url=$I_URL"

if [ "$I_STATE" != "OPEN" ]; then
  echo "stackon.sh: issue #$ISSUE is $I_STATE, not OPEN. Refusing to start work." >&2
  echo "  Reopen it first if you really want to work on it." >&2
  exit 1
fi

# --- Branch name: i<N>-<slug>, total length capped (same rule as workon) ---
MAX_NAME_LEN="${PI_STACKON_MAX_NAME_LEN:-${PI_WORKON_MAX_NAME_LEN:-16}}"
PREFIX="i${ISSUE}"
BRANCH="$(printf '%s\t%s\t%s' "$I_TITLE" "$PREFIX" "$MAX_NAME_LEN" | python3 -c '
import re, sys, unicodedata
title, prefix, cap_s = sys.stdin.read().split("\t")
cap = int(cap_s)
s = unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode().lower()
s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
s = re.sub(r"-+", "-", s)
name = prefix if not s else f"{prefix}-{s}"
name = name[:cap].rstrip("-")
if len(prefix) <= cap:
    name = name if name.startswith(prefix) else prefix[:cap].rstrip("-")
else:
    name = prefix[:cap].rstrip("-")
print(name)
')"

WORKTREE_DIR="${REPO_ROOT}/.worktrees/${BRANCH}"
echo "  branch=$BRANCH  (stacked on PR #$PR_NUM head: $PR_HEAD)"
echo "  worktree=$WORKTREE_DIR"

# --- Reuse existing worktree for this branch, if any ---------------------
EXISTING_PATH=""
mapfile -t WT_PAIRS < <(git worktree list --porcelain 2>/dev/null | python3 -c '
import sys
path = branch = None
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("worktree "):
        path = line[len("worktree "):]; branch = ""
    elif line.startswith("branch "):
        branch = line[len("branch "):].replace("refs/heads/", "")
    elif line.strip() == "" and path:
        print(f"{path}\t{branch}"); path = branch = None
if path:
    print(f"{path}\t{branch}")
')
for pair in "${WT_PAIRS[@]}"; do
  wt_path="${pair%%$'\t'*}"
  wt_branch="${pair##*$'\t'}"
  if [ "$wt_branch" = "$BRANCH" ]; then
    EXISTING_PATH="$wt_path"
    break
  fi
done

if [ -n "$EXISTING_PATH" ]; then
  echo
  echo "A worktree for branch '$BRANCH' already exists at:"
  echo "  $EXISTING_PATH"
  echo "Reusing it. cd there to continue."
  echo
  echo "WORKTREE_PATH=$EXISTING_PATH"
  echo "BRANCH=$BRANCH"
  echo "BASE_PR_URL=$PR_URL"
  echo "BASE_PR_HEAD=$PR_HEAD"
  echo "ISSUE_URL=$I_URL"
  echo
  echo "=== Issue body ==="
  printf '%s\n' "$I_BODY"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "[dry-run] would run: git fetch origin refs/pull/$PR/head"
  echo "[dry-run] would run: git worktree add -b $BRANCH $WORKTREE_DIR <pr-head-sha>"
  echo
  echo "=== Issue body (preview) ==="
  printf '%s\n' "$I_BODY"
  exit 0
fi

# --- Ensure .worktrees is ignored (local-only, does not touch .gitignore) -
EXCLUDE_FILE="${REPO_ROOT}/.git/info/exclude"
mkdir -p "${REPO_ROOT}/.git/info"
if ! grep -qxF ".worktrees/" "$EXCLUDE_FILE" 2>/dev/null; then
  printf '\n# pi stackon skill\n.worktrees/\n' >> "$EXCLUDE_FILE"
fi

# --- Fetch the PR's head commit (works for same-repo AND fork PRs) -------
# GitHub serves every PR's head at refs/pull/<N>/head on the base repo,
# so this works regardless of which fork owns the head branch.
echo "Fetching PR #$PR head (refs/pull/$PR/head)..."
git fetch --quiet origin "refs/pull/${PR}/head" 2>&1 || {
  echo "stackon.sh: git fetch refs/pull/$PR/head failed." >&2
  exit 1
}
BASE_SHA="$(git rev-parse FETCH_HEAD 2>/dev/null)" || {
  echo "stackon.sh: could not resolve the fetched PR head." >&2
  exit 1
}

# --- Create the worktree off the PR head commit --------------------------
# If the local branch already exists (e.g. from a previous aborted attempt),
# reuse it; otherwise create a new one off the PR head SHA.
if git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
  echo "Local branch '$BRANCH' already exists; checking it out in a new worktree..."
  git worktree add --force "$WORKTREE_DIR" "$BRANCH" 2>&1 || {
    echo "stackon.sh: git worktree add failed." >&2
    exit 1
  }
else
  echo "Creating worktree at $WORKTREE_DIR off PR #$PR head ($BASE_SHA)..."
  git worktree add -b "$BRANCH" "$WORKTREE_DIR" "$BASE_SHA" 2>&1 || {
    echo "stackon.sh: git worktree add failed." >&2
    exit 1
  }
fi

echo
echo "=== Summary ==="
echo "Stacked issue #$I_NUM on PR #$PR_NUM ($PR_TITLE)"
echo "  issue:    $I_URL"
echo "  base PR:  $PR_URL  (head: $PR_HEAD)"
echo "  branch:   $BRANCH  (off $BASE_SHA)"
echo "  worktree: $WORKTREE_DIR"
echo
echo "WORKTREE_PATH=$WORKTREE_DIR"
echo "BRANCH=$BRANCH"
echo "BASE_PR_URL=$PR_URL"
echo "BASE_PR_HEAD=$PR_HEAD"
echo "ISSUE_URL=$I_URL"
echo
echo "=== Issue body ==="
printf '%s\n' "$I_BODY"
echo
cat <<EOF
Done. cd into the worktree to begin.

Stacking notes:
- This branch is based on PR #$PR_NUM's head, not the default branch. When
  you open a PR for it, target the base PR's branch so GitHub shows the stack:
    gh pr create --base $PR_HEAD --head $BRANCH --title "..." --body-file <body>
- When the base PR merges, the stack collapses: rebase onto the default
  branch, force-push, and re-target the PR at main.
- If the base PR is force-pushed while you work, re-sync by re-running
  \`git fetch origin refs/pull/$PR/head\` and rebasing onto the new head.
EOF
