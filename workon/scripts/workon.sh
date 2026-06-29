#!/usr/bin/env bash
# workon.sh — start work on a GitHub issue in a fresh git worktree.
#
# Usage: workon.sh [--dry-run] <ISSUE#> [REPO]
#   --dry-run   Print what would happen; create nothing.
#   ISSUE#      required issue number
#   REPO        optional repo (owner/name); defaults to the current dir's repo
#
# What it does:
#   1. Fetches the issue (title, state, url, body) via `gh issue view`.
#   2. Aborts unless the issue is OPEN.
#   3. Derives a branch name: issue-<N>-<slug-of-title>.
#   4. If a worktree for that branch already exists, reuses it (prints the path).
#   5. Otherwise creates a worktree off origin/<default-branch> at
#      <repo_root>/.worktrees/<branch>, ensuring the path is in
#      .git/info/exclude so it never shows up as untracked in the main checkout.
#   6. Prints a summary: branch, worktree path, issue title/url, and the issue
#      body so the agent can begin implementing immediately.
#
# The script does NOT change the caller's cwd (it can't). The agent should run
# subsequent commands inside the printed WORKTREE_PATH.
set -uo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

ISSUE="${1:?usage: workon.sh [--dry-run] <ISSUE#> [REPO]}"
REPO="${2:-}"

# gh invocation (with optional --repo)
if [ -n "$REPO" ]; then GH=(gh --repo "$REPO"); else GH=(gh); fi

# Must be inside a git repo.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "workon.sh: not inside a git repository." >&2
  exit 1
}

# --- Fetch issue info ---
ISSUE_JSON="$("${GH[@]}" issue view "$ISSUE" --json number,title,state,url,body 2>/dev/null)" || {
  echo "workon.sh: could not fetch issue #$ISSUE (wrong number? not in a repo? gh auth?)" >&2
  exit 1
}

# Parse issue fields robustly using a unit separator so titles/bodies with
# spaces/newlines survive. The leading `read` is just to initialize vars.
IFS=$'\x1f' read -r NUM TITLE STATE URL BODY < <(printf '%s' "$ISSUE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
US = "\x1f"
sys.stdout.write(US.join([
  str(d.get("number","")),
  d.get("title",""),
  d.get("state",""),
  d.get("url",""),
  d.get("body","") or "",
]))
')

echo "Issue #$NUM: $TITLE"
echo "  state=$STATE  url=$URL"
[ "$DRY_RUN" = 1 ] && echo "(dry-run: nothing will be created)"

# --- State check ---
if [ "$STATE" != "OPEN" ]; then
  echo "workon.sh: issue #$ISSUE is $STATE, not OPEN. Refusing to start work." >&2
  echo "  Reopen it first if you really want to work on it." >&2
  exit 1
fi

# --- Slugify the title ---
SLUG="$(printf '%s' "$TITLE" | python3 -c '
import re, sys, unicodedata
s = sys.stdin.read()
s = unicodedata.normalize("NFKD", s).encode("ascii","ignore").decode()
s = s.lower()
s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
s = re.sub(r"-+", "-", s)
s = s[:60].rstrip("-")
print(s or "issue")
')"
BRANCH="issue-${ISSUE}-${SLUG}"

# --- Default branch (base for the worktree) ---
DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's@^origin/@@' 2>/dev/null)"
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="$("${GH[@]}" repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

WORKTREE_DIR="${REPO_ROOT}/.worktrees/${BRANCH}"

echo "  branch=$BRANCH"
echo "  base=origin/$DEFAULT_BRANCH"
echo "  worktree=$WORKTREE_DIR"

# --- Reuse existing worktree for this branch, if any ---
EXISTING_PATH=""
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
  echo "ISSUE_URL=$URL"
  echo
  echo "=== Issue body ==="
  printf '%s\n' "$BODY"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "[dry-run] would run: git fetch origin $DEFAULT_BRANCH"
  echo "[dry-run] would run: git worktree add -b $BRANCH $WORKTREE_DIR origin/$DEFAULT_BRANCH"
  echo
  echo "=== Issue body (preview) ==="
  printf '%s\n' "$BODY"
  exit 0
fi

# --- Ensure .worktrees is ignored (local-only, does not touch .gitignore) ---
EXCLUDE_FILE="${REPO_ROOT}/.git/info/exclude"
mkdir -p "${REPO_ROOT}/.git/info"
if ! grep -qxF ".worktrees/" "$EXCLUDE_FILE" 2>/dev/null; then
  printf '\n# pi workon skill\n.worktrees/\n' >> "$EXCLUDE_FILE"
fi

# --- Fetch base branch ---
echo "Fetching origin/$DEFAULT_BRANCH..."
git fetch --quiet origin "$DEFAULT_BRANCH" 2>&1 || {
  echo "workon.sh: git fetch origin/$DEFAULT_BRANCH failed." >&2
  exit 1
}

# --- Create the worktree ---
# If the local branch already exists (e.g. from a previous aborted attempt),
# reuse it; otherwise create a new one tracking origin/<default>.
if git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
  echo "Local branch '$BRANCH' already exists; checking it out in a new worktree..."
  git worktree add --force "$WORKTREE_DIR" "$BRANCH" 2>&1 || {
    echo "workon.sh: git worktree add failed." >&2
    exit 1
  }
else
  echo "Creating worktree at $WORKTREE_DIR off origin/$DEFAULT_BRANCH..."
  git worktree add -b "$BRANCH" "$WORKTREE_DIR" "origin/$DEFAULT_BRANCH" 2>&1 || {
    echo "workon.sh: git worktree add failed." >&2
    exit 1
  }
fi

echo
echo "=== Summary ==="
echo "Issue #$NUM: $TITLE"
echo "  url=$URL"
echo "  branch=$BRANCH"
echo "  worktree=$WORKTREE_DIR"
echo
echo "WORKTREE_PATH=$WORKTREE_DIR"
echo "BRANCH=$BRANCH"
echo "ISSUE_URL=$URL"
echo
echo "=== Issue body ==="
printf '%s\n' "$BODY"
echo
echo "Done. cd into the worktree to begin implementing the issue."
