#!/usr/bin/env bash
# triage-reopened.sh — list the default-closed triage queue: open issues/PRs
# labeled valid-reopened (auto-closed, then reopened by a human comment).
# Emits JSON; the model summarizes/prioritizes from it.
set -euo pipefail

COMMON_DIR="${SLOP_COMMON_DIR:-}"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$(dirname "$(readlink -f "$0")")/../../slop-common"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$HOME/.pi/agent/skills/skills/slop-common"
if [ ! -d "$COMMON_DIR" ]; then
  echo "triage-reopened: slop-common library not found (set SLOP_COMMON_DIR)" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$COMMON_DIR/repo.sh"
source "$COMMON_DIR/labels.sh"

REPO=""
WITH_SCORE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --score) WITH_SCORE=1; shift ;;
    --help|-h)
      sed -n '2,3p' "$0" | sed 's/^# //; s/^#//'
      echo
      echo "usage: triage-reopened.sh [--repo OWNER/NAME] [--score]"
      exit 0 ;;
    -*) echo "triage-reopened: unknown flag: $1" >&2; exit 2 ;;
    *) shift ;;
  esac
done

REPO=$(slop_resolve_repo "$REPO") || exit 1

# --- fetch the queue (search covers BOTH issues and PRs) ---
ITEMS_FILE=$(mktemp)
trap 'rm -f "$ITEMS_FILE"' EXIT
gh api -X GET search/issues -f q="repo:$REPO label:$SLOP_QUEUE_LABEL state:open" \
  --jq '.items' >"$ITEMS_FILE" 2>/dev/null || ITEMS_JSON='[]'
COUNT=$(jq 'length' "$ITEMS_FILE")

# --- fetch the allowlist ONCE (case-insensitive membership per author) ---
ALLOWLIST=$(gh api "repos/$REPO/contents/$SLOP_ALLOWLIST_PATH" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null) || ALLOWLIST=""
queue_in_allowlist() { [ -n "$ALLOWLIST" ] && grep -Fxqi -- "$1" <<<"$ALLOWLIST"; }

RESULT="[]"
while IFS= read -r N; do
  [ -z "$N" ] && continue
  # recent comments — the human follow-up that triggered reopen is among these
  COMMENTS=$(gh api "repos/$REPO/issues/$N/comments" \
    --jq '[.[] | {author:.user.login, created_at:.created_at, body:(.body // "")}]' 2>/dev/null || echo '[]')
  LOGIN=$(jq -r --arg n "$N" '.[] | select(.number==($n|tonumber)) | .user.login' "$ITEMS_FILE")
  ALLOWED=$(queue_in_allowlist "$LOGIN" && echo true || echo false)
  ONE=$(jq --arg n "$N" --argjson c "$COMMENTS" --argjson allowed "$ALLOWED" \
    '.[] | select(.number==($n|tonumber)) |
     { number, kind:(if .pull_request then "pr" else "issue" end),
       title, url:.html_url, author:(.user.login // "ghost"),
       created_at, state,
       is_allowlisted:$allowed,
       body_excerpt:((.body // "") | .[0:300]),
       recent_comments:$c }' "$ITEMS_FILE")

  if [ "$WITH_SCORE" = "1" ]; then
    # attach a full slop score (heavier: author stats + grounding per item)
    # shellcheck source=/dev/null
    source "$COMMON_DIR/collect.sh" "$COMMON_DIR/paths.sh" "$COMMON_DIR/score.sh" 2>/dev/null || true
    BODY=$(jq -r --arg n "$N" '.[] | select(.number==($n|tonumber)) | (.body // "")' "$ITEMS_FILE")
    AUTHOR_STATS=$(slop_collect_author "$REPO" "$LOGIN")
    CITED=$(slop_extract_cited_paths "$BODY" | jq -R -s 'split("\n")|map(select(length>0))')
    ROOT=$(slop_detect_repo_root "$REPO")
    SI=$(jq -n --arg l "$LOGIN" --argjson a "$(jq '.account_age_days' <<<"$AUTHOR_STATS")" \
            --argjson p "$(jq '.prior_contributions' <<<"$AUTHOR_STATS")" --argjson al "$ALLOWED" \
            --arg b "$BODY" --arg k "$KIND" --argjson cited "$CITED" --arg root "$ROOT" \
         '{login:$l, account_age_days:$a, prior_contributions:$p, is_allowlisted:$al, body:$b, kind:$k, cited_paths:$cited, repo_root:$root}')
    SCORE=$(slop_score <<<"$SI")
    ONE=$(jq -n --argjson one "$ONE" --argjson score "$SCORE" '$one + {score:$score}')
  fi

  RESULT=$(jq -n --argjson acc "$RESULT" --argjson one "$ONE" '$acc + [$one]')
done < <(jq -r '.[].number' "$ITEMS_FILE")

jq -n --arg repo "$REPO" --arg label "$SLOP_QUEUE_LABEL" --argjson count "$COUNT" \
       --argjson queue "$RESULT" \
  '{repo:$repo, label:$label, count:$count, queue:$queue}'
