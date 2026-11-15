#!/usr/bin/env bash
# workon.sh — start work on a GitHub issue in a fresh git worktree.
#
# Usage: workon.sh [--dry-run] [--base <BRANCH>] <ISSUE#> [REPO]
#   --dry-run   Print what would happen; create nothing.
#   --base BR   Base the worktree off origin/<BR> instead of the repo's default
#               branch (e.g. --base stable/1.0 for release-tracked work).
#   ISSUE#      required issue number
#   REPO        optional repo (owner/name); defaults to the current dir's repo
#
# Branch/worktree naming:
#   Names are i<N>-<short-slug> where the *total* length is capped
#   (prefix + slug together). The cap defaults to 16 (per the global
#   AGENTS.md worktree rule); override per-repo or per-invocation with
#   PI_WORKON_MAX_NAME_LEN (e.g. a repo whose AGENTS.md caps worktree dir
#   names at 20 chars sets PI_WORKON_MAX_NAME_LEN=20).
#
# What it does:
#   1. Fetches the issue (title, state, url, body) via `gh issue view`.
#   2. Aborts unless the issue is OPEN.
#   3. Derives a short branch name: i<N>-<slug> (total length capped).
#   4. If a worktree for that branch already exists, reuses it (prints the path).
#   5. Otherwise creates a worktree off origin/<base> (the repo's default
#      branch, or the one named by --base) at <repo_root>/.worktrees/<branch>,
#      ensuring the path is in
#      .git/info/exclude so it never shows up as untracked in the main checkout.
#   6. Prints a summary: branch, worktree path, issue title/url, and the issue
#      body so the agent can begin implementing immediately.
#
# The script does NOT change the caller's cwd (it can't). The agent should run
# subsequent commands inside the printed WORKTREE_PATH.
set -uo pipefail

DRY_RUN=0
BASE_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --base)
      [ $# -ge 2 ] || {
        echo "workon.sh: --base requires a branch name argument." >&2
        exit 2
      }
      BASE_OVERRIDE="$2"
      shift 2
      ;;
    --base=*)
      BASE_OVERRIDE="${1#--base=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "workon.sh: unknown option: $1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

ISSUE="${1:?usage: workon.sh [--dry-run] [--base <BRANCH>] <ISSUE#> [REPO]}"
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

# --- Branch name: i<N>-<short-slug>, total length capped -----------
# The cap bounds the WHOLE name (prefix + slug), not just the slug. Default
# 16 (global AGENTS.md worktree rule); PI_WORKON_MAX_NAME_LEN overrides
# (per-repo, e.g. a ≤20-char convention).
MAX_NAME_LEN="${PI_WORKON_MAX_NAME_LEN:-16}"
PREFIX="i${ISSUE}"
BRANCH="$(printf '%s\t%s\t%s' "$TITLE" "$PREFIX" "$MAX_NAME_LEN" | python3 -c '
import re, sys, unicodedata
title, prefix, cap_s = sys.stdin.read().split("\t")
cap = int(cap_s)
s = unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode()
s = s.lower()
s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
s = re.sub(r"-+", "-", s)
name = prefix if not s else f"{prefix}-{s}"
# Bound the TOTAL name. Truncate, then drop any trailing dash left over.
name = name[:cap].rstrip("-")
# A tiny cap could chop past the slug back into the prefix; keep at least
# the prefix (i<N>) which is the unique, required part.
if len(prefix) <= cap:
    name = name if name.startswith(prefix) else prefix[:cap].rstrip("-")
else:
    name = prefix[:cap].rstrip("-")
print(name)
')"

# --- Base branch for the worktree (origin/<base>) ---
# --base overrides; otherwise derive the repo's default branch
# (origin/HEAD, falling back to the repo's configured default, then 'main').
if [ -n "$BASE_OVERRIDE" ]; then
  BASE_BRANCH="$BASE_OVERRIDE"
else
  BASE_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's@^origin/@@' 2>/dev/null)"
  [ -z "$BASE_BRANCH" ] && BASE_BRANCH="$("${GH[@]}" repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
  [ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"
fi

WORKTREE_DIR="${REPO_ROOT}/.worktrees/${BRANCH}"

echo "  branch=$BRANCH"
echo "  base=origin/$BASE_BRANCH"
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
  echo "BASE=$(git -C "$EXISTING_PATH" config --get workon.base 2>/dev/null || echo "")"
  echo "ISSUE_URL=$URL"
  echo
  echo "=== Issue body ==="
  printf '%s\n' "$BODY"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "[dry-run] would run: git fetch origin $BASE_BRANCH"
  echo "[dry-run] would run: git worktree add -b $BRANCH $WORKTREE_DIR origin/$BASE_BRANCH"
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
echo "Fetching origin/$BASE_BRANCH..."
git fetch --quiet origin "$BASE_BRANCH" 2>&1 || {
  echo "workon.sh: git fetch origin/$BASE_BRANCH failed." >&2
  exit 1
}

# --- Create the worktree ---
# If the local branch already exists (e.g. from a previous aborted attempt),
# reuse it; otherwise create a new one off origin/<base>.
if git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
  echo "Local branch '$BRANCH' already exists; checking it out in a new worktree..."
  git worktree add --force "$WORKTREE_DIR" "$BRANCH" 2>&1 || {
    echo "workon.sh: git worktree add failed." >&2
    exit 1
  }
else
  echo "Creating worktree at $WORKTREE_DIR off origin/$BASE_BRANCH..."
  git worktree add -b "$BRANCH" "$WORKTREE_DIR" "origin/$BASE_BRANCH" 2>&1 || {
    echo "workon.sh: git worktree add failed." >&2
    exit 1
  }
fi

# --- Record the base branch in the worktree ---
# Later steps (rebase target, PR --base, structure artifacts) must use the
# same base the worktree was created from; git config in the worktree keeps
# it across sessions (read with: git config --get workon.base).
git -C "$WORKTREE_DIR" config workon.base "$BASE_BRANCH"

echo
echo "=== Summary ==="
echo "Issue #$NUM: $TITLE"
echo "  url=$URL"
echo "  branch=$BRANCH"
echo "  worktree=$WORKTREE_DIR"
echo
echo "WORKTREE_PATH=$WORKTREE_DIR"
echo "BRANCH=$BRANCH"
echo "BASE=$BASE_BRANCH"
echo "ISSUE_URL=$URL"
echo
echo "=== Issue body ==="
printf '%s\n' "$BODY"
echo
echo "Done. cd into the worktree to begin implementing the issue."
