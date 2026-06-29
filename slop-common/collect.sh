# shellcheck shell=bash
# slop-common/collect.sh — fetch author stats used by the score.
# Sourced by the policy skills. Exposes: slop_collect_author
#
# "Prior contributions" = number of issues + PRs authored by <login> in <repo>,
# via the search API. It's an engagement proxy, not a commit count — good enough
# for scoring and cheap (one search call).

# slop_collect_author <repo> <login>
# Emits JSON: {"login","account_age_days","prior_contributions"}
slop_collect_author() {
  local repo="$1" login="$2"
  local created_at age_days=0 prior=0

  created_at=$(gh api "users/$login" --jq '.created_at' 2>/dev/null) || created_at=""
  if [ -n "$created_at" ]; then
    # ISO8601 -> days since account creation (floor).
    age_days=$(jq -rn --arg c "$created_at" '($c | fromdateiso8601) as $t | ((now - $t)/86400 | floor)') || age_days=0
  fi

  # search/issues covers both issues and PRs; total_count is the engagement count.
  prior=$(gh api -X GET search/issues -f q="repo:$repo author:$login" \
    --jq '.total_count' 2>/dev/null) || prior=0

  jq -rn \
    --arg l "$login" \
    --argjson a "$age_days" \
    --argjson p "$prior" \
    '{login:$l, account_age_days:$a, prior_contributions:$p}'
}
