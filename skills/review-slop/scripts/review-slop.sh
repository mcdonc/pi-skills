#!/usr/bin/env bash
# review-slop.sh — fetch one issue/PR with full context + a 0-100 slop score.
# Emits JSON; the model writes the assessment/recommendation.
set -euo pipefail

# Resolve the shared library (three-tier fallback, see slop-common/README.md).
COMMON_DIR="${SLOP_COMMON_DIR:-}"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$(dirname "$(readlink -f "$0")")/../../slop-common"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$HOME/.pi/agent/skills/skills/slop-common"
if [ ! -d "$COMMON_DIR" ]; then
  echo "review-slop: slop-common library not found (set SLOP_COMMON_DIR)" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$COMMON_DIR/repo.sh"
source "$COMMON_DIR/labels.sh"
source "$COMMON_DIR/collect.sh"
source "$COMMON_DIR/paths.sh"
source "$COMMON_DIR/score.sh"

REPO=""
NUMBER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,4p' "$0" | sed 's/^# //; s/^#//'
      echo
      echo "usage: review-slop.sh [--repo OWNER/NAME] <ISSUE_OR_PR_NUMBER|URL>"
      exit 0 ;;
    -*) echo "review-slop: unknown flag: $1" >&2; exit 2 ;;
    *) NUMBER="$1"; shift ;;
  esac
done

[ -n "$NUMBER" ] || { echo "review-slop: need an issue/PR number (or URL)" >&2; exit 2; }
NUMBER=$(printf '%s' "$NUMBER" | grep -oE '[0-9]+' | tail -1)
[ -n "$NUMBER" ] || { echo "review-slop: could not parse a number from the argument" >&2; exit 2; }

REPO=$(slop_resolve_repo "$REPO") || exit 1

# --- fetch the unified issue/PR object (PRs are issues with a .pull_request key) ---
RAW=$(gh api "repos/$REPO/issues/$NUMBER" 2>/dev/null) || {
  echo "review-slop: could not fetch #$NUMBER from $REPO" >&2; exit 1; }

LOGIN=$(jq -r '.user.login // "ghost"' <<<"$RAW")
BODY=$(jq -r '.body // ""' <<<"$RAW")
TITLE=$(jq -r '.title // ""' <<<"$RAW")
URL=$(jq -r '.html_url // ""' <<<"$RAW")
STATE=$(jq -r '.state // ""' <<<"$RAW")
LABELS=$(jq '[.labels[].name] // []' <<<"$RAW")
KIND=$(jq -r 'if .pull_request then "pr" else "issue" end' <<<"$RAW")
BODY_LEN=$(printf '%s' "$BODY" | wc -c | tr -d ' ')

# --- author stats + allowlist membership ---
AUTHOR=$(slop_collect_author "$REPO" "$LOGIN")
ALLOWED=$(slop_is_allowed "$REPO" "$LOGIN")
AUTHOR=$(jq --argjson a "$([ "$ALLOWED" = "true" ] && echo true || echo false)" \
  '. + {is_allowlisted:$a}' <<<"$AUTHOR")

# --- comments (author + body) ---
COMMENTS=$(gh api "repos/$REPO/issues/$NUMBER/comments" \
  --jq '[.[] | {author:.user.login, created_at:.created_at, body:.body}]' 2>/dev/null || echo '[]')

# --- PR files (if a PR) ---
PR_FILES='[]'
if [ "$KIND" = "pr" ]; then
  PR_FILES=$(gh pr view "$NUMBER" --repo "$REPO" --json 'files' \
    --jq '[.files[].path]' 2>/dev/null || echo '[]')
fi

# --- cited paths from prose (body + comment bodies), for the grounding check ---
COMMENT_BODIES=$(jq -r '[.[].body] | join("\n")' <<<"$COMMENTS")
CITED_JSON=$(slop_extract_cited_paths "$BODY"$'\n'"$COMMENT_BODIES" | jq -R -s 'split("\n")|map(select(length>0))')

# --- repo checkout for grounding (empty => grounding skipped, neutral) ---
REPO_ROOT=$(slop_detect_repo_root "$REPO")

# --- assemble score input and score ---
SCORE_INPUT=$(jq -n \
  --arg login "$LOGIN" \
  --argjson age "$(jq '.account_age_days' <<<"$AUTHOR")" \
  --argjson prior "$(jq '.prior_contributions' <<<"$AUTHOR")" \
  --argjson allowed "$([ "$ALLOWED" = "true" ] && echo true || echo false)" \
  --arg body "$BODY" \
  --arg kind "$KIND" \
  --argjson cited "$CITED_JSON" \
  --arg repo_root "$REPO_ROOT" \
  '{login:$login, account_age_days:$age, prior_contributions:$prior,
    is_allowlisted:$allowed, body:$body, kind:$kind,
    cited_paths:$cited, repo_root:$repo_root}')
SCORE=$(slop_score <<<"$SCORE_INPUT")

# --- final envelope ---
jq -n \
  --arg repo "$REPO" \
  --argjson number "$NUMBER" \
  --arg kind "$KIND" \
  --arg title "$TITLE" \
  --arg url "$URL" \
  --arg state "$STATE" \
  --argjson labels "$LABELS" \
  --argjson author "$AUTHOR" \
  --arg body "$BODY" \
  --argjson body_len "$BODY_LEN" \
  --argjson comments "$COMMENTS" \
  --argjson pr_files "$PR_FILES" \
  --argjson cited "$CITED_JSON" \
  --argjson score "$SCORE" \
  '{repo:$repo, number:$number, kind:$kind, title:$title, url:$url, state:$state,
    labels:$labels, author:$author, body:$body, body_len:$body_len,
    comments:$comments, pr_files:$pr_files, cited_paths:$cited, score:$score}'
