# shellcheck shell=bash
# slop-common/paths.sh — extract file-path-like tokens from text.
# Sourced by review-slop and slop-report. Exposes: slop_extract_cited_paths

# slop_extract_cited_paths [text...]
#   Reads text from args (joined) or stdin. Emits newline-separated, de-duplicated
#   path candidates found in the text: tokens shaped like `word/word.ext`
#   (a slash + a dotted extension). URLs and bare version numbers are filtered.
#   Backticks don't matter — the engine matches the path inside them anyway.
slop_extract_cited_paths() {
  local text
  if [ "$#" -gt 0 ]; then text="$*"; else text=$(cat); fi
  # Each grep is wrapped in `{ ... || true; }` so a "no match" (exit 1) doesn't
  # propagate through pipefail and abort a `set -e` caller — the common case is
  # a body with NO path-shaped tokens, which must yield empty output, not crash.
  printf '%s\n' "$text" \
    | { grep -oE '[A-Za-z0-9_.][A-Za-z0-9_./-]*/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' 2>/dev/null || true; } \
    | { grep -vE '://' || true; } \
    | { grep -vE '^[0-9.]+$' || true; } \
    | sort -u
}
