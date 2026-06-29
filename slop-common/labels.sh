# shellcheck shell=bash
# slop-common/labels.sh — the two policy labels + allowlist membership.
# Sourced by the policy skills. Exposes: SLOP_QUEUE_LABEL, SLOP_AUTOCLOSED_LABEL,
# SLOP_ALLOWLIST_PATH, slop_is_allowed

# The triage-queue label (set by auto-reopen, removed by /reopen or /keep-closed).
SLOP_QUEUE_LABEL="${SLOP_QUEUE_LABEL:-valid-reopened}"
# The ephemeral "eligible for auto-reopen" label (set by auto-close, removed by auto-reopen).
SLOP_AUTOCLOSED_LABEL="${SLOP_AUTOCLOSED_LABEL:-auto-closed}"
# Relative path to the allowlist inside the repo (one login per line, # comments).
SLOP_ALLOWLIST_PATH="${SLOP_ALLOWLIST_PATH:-.github/slop-allowlist}"

# slop_is_allowed <repo> <login> -> echoes "true" / "false".
#
# GitHub logins are case-insensitive, so the match is case-insensitive (-i):
# a trusted contributor shouldn't be missed just because their login arrived in
# a different case. (The auto-close workflow matches case-sensitively on the
# webhook's canonical-case login; here we're answering the advisory question
# "is this author trusted?" where a false negative is the worse failure.)
slop_is_allowed() {
  local repo="$1" login="$2" content
  if [ -z "$login" ]; then
    echo false
    return 0
  fi
  content=$(gh api "repos/$repo/contents/$SLOP_ALLOWLIST_PATH" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null) || true
  if [ -z "$content" ]; then
    echo false
    return 0
  fi
  # Strip comments + blank lines, then case-insensitive exact-line match.
  if printf '%s\n' "$content" | grep -vE '^[[:space:]]*(#|$)' | grep -Fxqi -- "$login"; then
    echo true
  else
    echo false
  fi
}
