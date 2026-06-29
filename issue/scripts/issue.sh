#!/usr/bin/env bash
# issue.sh — open a GitHub issue from a title + body.
#
# Usage: issue.sh --title <TITLE> --body <BODY|-> [--repo <OWNER/NAME>] [--label <L>...]
#                 [--assignee <A>...] [--milestone <M>] [--project <P>...]
#
#   --title   required. The issue title.
#   --body    required. Issue body text, or `-` to read from stdin.
#   --repo    optional. owner/name of the repo to file in. Defaults to the
#             repo of the current working directory (detected via gh).
#   --label   repeatable. Adds labels (skipped silently if a label doesn't exist).
#   --assignee repeatable. Assigns users (`@me` resolves to the current user).
#   --milestone optional. Milestone title or number.
#   --project  repeatable. Project titles or numbers to add the issue to.
#
# The script does NOT summarize text — the caller (the agent) is responsible for
# producing a concise title and well-structured body from the user's description.
# This script just resolves the target repo and runs `gh issue create`.
set -uo pipefail

TITLE=""
BODY=""
REPO=""
LABELS=()
ASSIGNEES=()
MILESTONE=""
PROJECTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --title)     TITLE="$2"; shift 2 ;;
    --body)      BODY="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --label)     LABELS+=("$2"); shift 2 ;;
    --assignee)  ASSIGNEES+=("$2"); shift 2 ;;
    --milestone) MILESTONE="$2"; shift 2 ;;
    --project)   PROJECTS+=("$2"); shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *)
      echo "issue.sh: unknown argument '$1'" >&2
      exit 2 ;;
  esac
done

[ -n "$TITLE" ] || { echo "issue.sh: --title is required" >&2; exit 2; }
[ -n "$BODY" ]  || { echo "issue.sh: --body is required (use '-' for stdin)" >&2; exit 2; }

# --- Resolve target repo ---
# Explicit --repo wins. Otherwise derive from the current dir's git remote via gh.
if [ -z "$REPO" ]; then
  if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "issue.sh: not inside a git repo and no --repo given. Pass --repo owner/name." >&2
    exit 1
  fi
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || {
    echo "issue.sh: could not resolve repo from cwd (gh auth? remote?)." >&2
    exit 1
  }
fi
echo "Target repo: $REPO"

# --- Body from stdin if requested ---
BODY_FILE=""
if [ "$BODY" = "-" ]; then
  BODY_FILE="$(mktemp)"
  trap 'rm -f "$BODY_FILE"' EXIT
  cat > "$BODY_FILE"
  BODY_ARG=(--body-file "$BODY_FILE")
else
  BODY_ARG=(--body "$BODY")
fi

# --- Build gh args ---
GH=(gh issue create --repo "$REPO" --title "$TITLE" "${BODY_ARG[@]}")

if [ ${#LABELS[@]} -gt 0 ]; then
  for L in "${LABELS[@]}"; do GH+=(--label "$L"); done
fi
if [ ${#ASSIGNEES[@]} -gt 0 ]; then
  for A in "${ASSIGNEES[@]}"; do
    [ "$A" = "@me" ] && A="$(gh api user --jq .login 2>/dev/null)"
    GH+=(--assignee "$A")
  done
fi
[ -n "$MILESTONE" ] && GH+=(--milestone "$MILESTONE")
if [ ${#PROJECTS[@]} -gt 0 ]; then
  for P in "${PROJECTS[@]}"; do GH+=(--project "$P"); done
fi

# --- Create ---
# gh exits non-zero if a label/assignee/project doesn't apply; fall back to a
# bare create so the issue still opens, then report what was skipped.
URL="$("${GH[@]}" 2>&1)" || {
  echo "issue.sh: full create failed; retrying without labels/assignees/projects:"
  echo "  $URL"
  URL="$(gh issue create --repo "$REPO" --title "$TITLE" "${BODY_ARG[@]}" 2>&1)" || {
    echo "issue.sh: gh issue create failed:" >&2
    echo "  $URL" >&2
    exit 1
  }
  echo "  (created without labels/assignees/projects — add them via the web UI)"
}

echo "$URL"
