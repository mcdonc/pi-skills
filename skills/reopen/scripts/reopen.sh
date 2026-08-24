#!/usr/bin/env bash
# reopen.sh — apply a PROMOTE decision on a triage item: drop it from the queue
# (remove valid-reopened), ensure it's open, optionally assign / relabel / trust
# the author (allowlist PR), and post an ack comment. Emits a summary.
set -uo pipefail

COMMON_DIR="${SLOP_COMMON_DIR:-}"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$(dirname "$(readlink -f "$0")")/../slop-common"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$HOME/.pi/agent/skills/slop-common"
if [ ! -d "$COMMON_DIR" ]; then echo "reopen: slop-common not found" >&2; exit 1; fi
# shellcheck source=/dev/null
source "$COMMON_DIR/repo.sh"
source "$COMMON_DIR/labels.sh"

# --- helpers (defined before use) ---
DRY=0
# Array-based: safe for bodies containing quotes/apostrophes/newlines (no eval).
run() { if [ "$DRY" = "1" ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# Open an allowlist PR for <login> via a shallow temp clone (isolated subshell,
# so the caller's cwd is untouched). Prints the PR URL on success.
reopen_trust_author() {
  local repo="$1" login="$2" branch base tmp
  tmp=$(mktemp -d) || return 1
  branch="allowlist-add-${login}"
  base=$(gh repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
  (
    set -e
    cd "$tmp"
    gh repo clone "$repo" . -- --depth 1 --quiet 2>/dev/null
    git checkout -b "$branch" --quiet
    # already trusted? skip the PR.
    if [ -f "$SLOP_ALLOWLIST_PATH" ] && grep -Fxqi -- "$login" "$SLOP_ALLOWLIST_PATH"; then
      echo "(already in allowlist)"
      exit 0
    fi
    printf '%s\n' "$login" >> "$SLOP_ALLOWLIST_PATH"
    git add "$SLOP_ALLOWLIST_PATH"
    git commit -m "chore(policy): add $login to slop allowlist" --quiet
    git push -u origin "$branch" --quiet 2>/dev/null
    gh pr create --repo "$repo" --base "$base" --head "$branch" \
      --title "chore(policy): add $login to slop allowlist" \
      --body "Adds @$login to \`$SLOP_ALLOWLIST_PATH\` (trusted by maintainer on triage)."
  )
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

# --- args ---
REPO=""
NUMBER=""
ASSIGN=""
ADD_LABELS=()
TRUST=0
COMMENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --assign) ASSIGN="$2"; shift 2 ;;
    --add-label) ADD_LABELS+=("$2"); shift 2 ;;
    --trust-author) TRUST=1; shift ;;
    --comment) COMMENT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --help|-h) sed -n '2,3p' "$0" | sed 's/^# //'; echo; echo "usage: reopen.sh [--repo R] [--assign L] [--add-label L]... [--trust-author] [--comment BODY|-] [--dry-run] <#>"; exit 0 ;;
    -*) echo "reopen: unknown flag: $1" >&2; exit 2 ;;
    *) NUMBER="$1"; shift ;;
  esac
done
[ -n "$NUMBER" ] || { echo "reopen: need an issue/PR number" >&2; exit 2; }
NUMBER=$(printf '%s' "$NUMBER" | grep -oE '[0-9]+' | tail -1)
REPO=$(slop_resolve_repo "$REPO") || exit 1

RAW=$(gh api "repos/$REPO/issues/$NUMBER" 2>/dev/null) || { echo "reopen: #$NUMBER not found in $REPO" >&2; exit 1; }
KIND=$(jq -r 'if .pull_request then "pr" else "issue" end' <<<"$RAW")
AUTHOR=$(jq -r '.user.login // ""' <<<"$RAW")
G="$KIND"   # gh subcommands (comment/edit/reopen) exist for both 'issue' and 'pr'

echo "reopen: #$NUMBER ($KIND) in $REPO$([ "$DRY" = "1" ] && echo ' [DRY-RUN]')"

# 1. drop the queue label
run gh "$G" edit "$NUMBER" --repo "$REPO" --remove-label "$SLOP_QUEUE_LABEL" || true
# 2. ensure open
run gh "$G" reopen "$NUMBER" --repo "$REPO" || true
# 3. assign / relabel (best-effort — missing labels/users must not abort the decision)
[ -n "$ASSIGN" ] && { run gh "$G" edit "$NUMBER" --repo "$REPO" --add-assignee "$ASSIGN" || echo "  warn: assign failed" >&2; }
for L in "${ADD_LABELS[@]:-}"; do [ -n "$L" ] && { run gh "$G" edit "$NUMBER" --repo "$REPO" --add-label "$L" || echo "  warn: add-label '$L' failed (does it exist?)" >&2; }; done
# 4. trust-author -> allowlist PR
if [ "$TRUST" = "1" ] && [ -n "$AUTHOR" ]; then
  echo "  trust-author: opening allowlist PR for @$AUTHOR"
  pr_url=$(reopen_trust_author "$REPO" "$AUTHOR") || pr_url="(failed to open allowlist PR)"
  echo "  allowlist PR: $pr_url"
fi
# 5. ack comment
if [ -z "$COMMENT" ]; then
  COMMENT="Triaged and kept open — thanks. Removed from the review queue."
else
  [ "$COMMENT" = "-" ] && COMMENT="$(cat)"
fi
run gh "$G" comment "$NUMBER" --repo "$REPO" --body "$COMMENT" || echo "  warn: comment failed" >&2
echo "reopen: done."
