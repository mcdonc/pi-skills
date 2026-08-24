#!/usr/bin/env bash
# keep-closed.sh — apply a KEEP-CLOSED decision on a triage item: re-close it,
# drop it from the queue (remove valid-reopened), and post an ack comment.
# Emits a summary.
set -uo pipefail

COMMON_DIR="${SLOP_COMMON_DIR:-}"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$(dirname "$(readlink -f "$0")")/../slop-common"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$HOME/.pi/agent/skills/slop-common"
if [ ! -d "$COMMON_DIR" ]; then echo "keep-closed: slop-common not found" >&2; exit 1; fi
# shellcheck source=/dev/null
source "$COMMON_DIR/repo.sh"
source "$COMMON_DIR/labels.sh"

DRY=0
# Array-based: safe for bodies containing quotes/apostrophes/newlines (no eval).
run() { if [ "$DRY" = "1" ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

REPO=""
NUMBER=""
COMMENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --comment) COMMENT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --help|-h) sed -n '2,3p' "$0" | sed 's/^# //'; echo; echo "usage: keep-closed.sh [--repo R] [--comment BODY|-] [--dry-run] <#>"; exit 0 ;;
    -*) echo "keep-closed: unknown flag: $1" >&2; exit 2 ;;
    *) NUMBER="$1"; shift ;;
  esac
done
[ -n "$NUMBER" ] || { echo "keep-closed: need an issue/PR number" >&2; exit 2; }
NUMBER=$(printf '%s' "$NUMBER" | grep -oE '[0-9]+' | tail -1)
REPO=$(slop_resolve_repo "$REPO") || exit 1

RAW=$(gh api "repos/$REPO/issues/$NUMBER" 2>/dev/null) || { echo "keep-closed: #$NUMBER not found in $REPO" >&2; exit 1; }
KIND=$(jq -r 'if .pull_request then "pr" else "issue" end' <<<"$RAW")
G="$KIND"

if [ -z "$COMMENT" ]; then
  COMMENT="Closing as low-signal for now. If this is a real issue, reply with more detail (what you tried, how to reproduce, why it matters) and we'll reopen. Thanks."
else
  [ "$COMMENT" = "-" ] && COMMENT="$(cat)"
fi

echo "keep-closed: #$NUMBER ($KIND) in $REPO$([ "$DRY" = "1" ] && echo ' [DRY-RUN]')"

# 1. ack comment (while still open + in queue)
run gh "$G" comment "$NUMBER" --repo "$REPO" --body "$COMMENT" || echo "  warn: comment failed" >&2
# 2. re-close
run gh "$G" close "$NUMBER" --repo "$REPO"
# 3. drop the queue label (best-effort)
run gh "$G" edit "$NUMBER" --repo "$REPO" --remove-label "$SLOP_QUEUE_LABEL" || true
echo "keep-closed: done."
