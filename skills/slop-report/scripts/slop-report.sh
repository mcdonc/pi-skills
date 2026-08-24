#!/usr/bin/env bash
# slop-report.sh — delta slop report over a time window of issues/PRs opened in
# that window, each with a 0-100 slop score. The time-based safety net that
# catches false negatives the reopen path missed (legit items auto-closed that
# nobody challenged). Emits JSON.
#
# Window:
#   (default)         since-last-run (persisted cursor); ADVANCES the cursor
#   "since yesterday" | "last week" | "since YYYY-MM-DD" | "YYYY-MM-DD..YYYY-MM-DD"
#                     explicit period; does NOT advance the cursor
#   --days N | --since DATE | --range A..B   explicit-period flag forms
set -uo pipefail

COMMON_DIR="${SLOP_COMMON_DIR:-}"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$(dirname "$(readlink -f "$0")")/../../slop-common"
[ -d "$COMMON_DIR" ] || COMMON_DIR="$HOME/.pi/agent/skills/skills/slop-common"
if [ ! -d "$COMMON_DIR" ]; then echo "slop-report: slop-common not found" >&2; exit 1; fi
# shellcheck source=/dev/null
source "$COMMON_DIR/repo.sh"
source "$COMMON_DIR/labels.sh"
source "$COMMON_DIR/collect.sh"
source "$COMMON_DIR/paths.sh"
source "$COMMON_DIR/score.sh"

REPO=""
PERIOD=""
DAYS=""
SINCE=""
RANGE=""
LIMIT=100
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --range) RANGE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --help|-h) sed -n '2,8p' "$0" | sed 's/^# //'; echo; echo "usage: slop-report.sh [--repo R] [PERIOD|--days N|--since DATE|--range A..B] [--limit N]"; exit 0 ;;
    -*) echo "slop-report: unknown flag: $1" >&2; exit 2 ;;
    *) PERIOD="$1"; shift ;;
  esac
done
REPO=$(slop_resolve_repo "$REPO") || exit 1

SLOP_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/pi-slop"
cursor_file() { printf '%s/cursor-%s.json\n' "$SLOP_STATE_DIR" "$(printf '%s' "$1" | tr '/:' '__')"; }
cursor_read() { local f; f=$(cursor_file "$1"); [ -f "$f" ] && jq -r '.last_run // empty' "$f" 2>/dev/null || true; }
cursor_write() { local f; f=$(cursor_file "$1"); mkdir -p "$(dirname "$f")"; jq -n --arg repo "$1" --arg ts "$2" '{repo:$repo,last_run:$ts}' > "$f"; }

today() { date -u +%Y-%m-%d; }
days_ago() { date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"$1"d +%Y-%m-%d; }
date_of() { date -u -d "$1" +%Y-%m-%d 2>/dev/null || printf '%s' "$1"; }

# --- resolve window -> FROM, TO, MODE, ADVANCE ---
ADVANCE=0
TO=$(today)
MODE=""
if [ -n "$PERIOD" ]; then
  case "$PERIOD" in
    "since yesterday") FROM=$(days_ago 1); MODE="since-yesterday" ;;
    "last week") FROM=$(days_ago 7); MODE="last-week" ;;
    since\ *) FROM=$(date_of "${PERIOD#since }"); MODE="since" ;;
    *..*) FROM=$(printf '%s' "$PERIOD" | cut -d. -f1); TO=$(printf '%s' "$PERIOD" | cut -d. -f3); MODE="range" ;;
    *) echo "slop-report: unrecognized period '$PERIOD' (try: 'since yesterday', 'last week', 'since 2026-06-01', '2026-06-01..2026-06-15', --days N)" >&2; exit 2 ;;
  esac
elif [ -n "$DAYS" ]; then FROM=$(days_ago "$DAYS"); MODE="days"
elif [ -n "$SINCE" ]; then FROM=$(date_of "$SINCE"); MODE="since"
elif [ -n "$RANGE" ]; then FROM=$(printf '%s' "$RANGE" | cut -d. -f1); TO=$(printf '%s' "$RANGE" | cut -d. -f3); MODE="range"
else
  # default: since-last-run cursor
  LAST=$(cursor_read "$REPO")
  if [ -n "$LAST" ]; then FROM=$(date_of "${LAST%%T*}"); else FROM=$(days_ago 30); fi
  MODE="cursor"; ADVANCE=1
fi

[ -n "$FROM" ] && [ -n "$TO" ] || { echo "slop-report: could not resolve window" >&2; exit 2; }

# --- fetch items opened in the window (search covers issues AND PRs) ---
ITEMS=$(gh api -X GET search/issues -f q="repo:$REPO created:$FROM..$TO" \
  --paginate --jq '.items[]' 2>/dev/null | jq -s '.' | jq --argjson lim "$LIMIT" '.[0:$lim]')
COUNT=$(jq 'length' <<<"$ITEMS")

# --- triage queue membership (items currently labeled valid-reopened) ---
QUEUE_SET=$(gh api -X GET search/issues -f q="repo:$REPO label:$SLOP_QUEUE_LABEL state:open" \
  --paginate --jq '.items[].number' 2>/dev/null | jq -s 'map(tostring)')

# --- allowlist (one fetch) ---
ALLOWLIST=$(gh api "repos/$REPO/contents/$SLOP_ALLOWLIST_PATH" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null) || ALLOWLIST=""
in_allowlist() { [ -n "$ALLOWLIST" ] && grep -Fxqi -- "$1" <<<"$ALLOWLIST"; }

# --- repo checkout for grounding ---
REPO_ROOT=$(slop_detect_repo_root "$REPO")

# --- author-stats cache (dedupe across items) ---
declare -A AGE_CACHE PRIOR_CACHE

emit() {
  jq -n --arg repo "$REPO" --arg from "$FROM" --arg to "$TO" --arg mode "$MODE" \
        --argjson advance "$ADVANCE" --argjson count "$COUNT" \
        --argjson items "$ITEMS_JSON" --argjson tally "$TALLY" \
        --arg next_cursor "${NEXT_CURSOR:-null}" \
    '{repo:$repo, window:{from:$from,to:$to,mode:$mode,advanced_cursor:($advance==1)},
      tally:$tally, count:$count, items:$items, next_cursor:($next_cursor)}'
}

ITEMS_JSON="[]"
TALLY='{"total":0,"closed_auto_closed":0,"open_valid_reopened":0,"open_other":0,"closed_other":0}'
while IFS= read -r LINE; do
  # LINE is tab-separated: number<TAB>kind<TAB>login<TAB>state<TAB>labels(json)<TAB>body
  [ -z "$LINE" ] && continue
  NUMBER=$(printf '%s' "$LINE" | cut -f1)
  KIND=$(printf '%s' "$LINE" | cut -f2)
  LOGIN=$(printf '%s' "$LINE" | cut -f3)
  STATE=$(printf '%s' "$LINE" | cut -f4)
  LABELS=$(printf '%s' "$LINE" | cut -f5)
  BODY=$(printf '%s' "$LINE" | cut -f6-)

  ALLOWED=$(in_allowlist "$LOGIN" && echo true || echo false)
  IN_TRIAGE=$(jq --argjson q "$QUEUE_SET" --arg n "$NUMBER" '$q | index($n) != null' <<<"{}")
  HAS_AUTO=$(jq --argjson l "$LABELS" '[$l[]] | index("auto-closed") != null' <<<"{}")

  # author stats (cached)
  if [ -z "${AGE_CACHE[$LOGIN]:-}" ]; then
    STATS=$(slop_collect_author "$REPO" "$LOGIN")
    AGE_CACHE[$LOGIN]=$(jq '.account_age_days' <<<"$STATS")
    PRIOR_CACHE[$LOGIN]=$(jq '.prior_contributions' <<<"$STATS")
  fi
  AGE=${AGE_CACHE[$LOGIN]}; PRIOR=${PRIOR_CACHE[$LOGIN]}

  CITED=$(slop_extract_cited_paths "$BODY" | jq -R -s 'split("\n")|map(select(length>0))')
  SI=$(jq -n --arg l "$LOGIN" --argjson a "$AGE" --argjson p "$PRIOR" --argjson al "$ALLOWED" \
            --arg b "$BODY" --arg k "$KIND" --argjson cited "$CITED" --arg root "$REPO_ROOT" \
       '{login:$l, account_age_days:$a, prior_contributions:$p, is_allowlisted:$al, body:$b, kind:$k, cited_paths:$cited, repo_root:$root}')
  SCORE=$(slop_score <<<"$SI")

  # bucket: in_triage (demoted) > false_negative > borderline > confirmed_slop
  SCORE_VAL=$(jq -r '.score' <<<"$SCORE")
  if [ "$IN_TRIAGE" = "true" ]; then BUCKET="in_triage"
  elif [ "$STATE" = "closed" ] && [ "$SCORE_VAL" -ge 60 ]; then BUCKET="false_negative"
  elif [ "$SCORE_VAL" -ge 35 ]; then BUCKET="borderline"
  else BUCKET="confirmed_slop"; fi

  ONE=$(jq -n --argjson n "$NUMBER" --arg kind "$KIND" --arg login "$LOGIN" --arg state "$STATE" \
            --argjson allowed "$ALLOWED" --argjson in_triage "$IN_TRIAGE" --argjson has_auto "$HAS_AUTO" \
            --argjson score "$SCORE" --arg bucket "$BUCKET" \
        '{number:$n, kind:$kind, author:$login, state:$state,
          is_allowlisted:$allowed, in_triage_queue:$in_triage, was_auto_closed:$has_auto,
          score:$score.score, components:$score.components, reasons:$score.reasons, bucket:$bucket}')

  ITEMS_JSON=$(jq -n --argjson acc "$ITEMS_JSON" --argjson one "$ONE" '$acc + [$one]')

  # tally
  case "$STATE/$IN_TRIAGE/$HAS_AUTO" in
    closed/*true) TALLY=$(jq '.closed_auto_closed += 1' <<<"$TALLY") ;;
    open/true/*)  TALLY=$(jq '.open_valid_reopened += 1' <<<"$TALLY") ;;
    open/false/*) TALLY=$(jq '.open_other += 1' <<<"$TALLY") ;;
    closed/false/*)TALLY=$(jq '.closed_other += 1' <<<"$TALLY") ;;
  esac
  TALLY=$(jq '.total += 1' <<<"$TALLY")
done < <(jq -r '.[] | [.number, (if .pull_request then "pr" else "issue" end), (.user.login // "ghost"), .state, ([.labels[].name] | @json), (.body // "")] | @tsv' <<<"$ITEMS")

# --- sort: false_negative (score desc) -> borderline -> confirmed_slop -> in_triage ---
ITEMS_JSON=$(jq '
  def pri: {"false_negative":0,"borderline":1,"confirmed_slop":2,"in_triage":3}[.];
  sort_by((.bucket|pri), -(.score // 0))' <<<"$ITEMS_JSON")

# --- advance cursor ---
if [ "$ADVANCE" = "1" ]; then
  NEXT_CURSOR=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cursor_write "$REPO" "$NEXT_CURSOR"
fi

emit
