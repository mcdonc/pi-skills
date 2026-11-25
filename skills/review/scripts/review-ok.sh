#!/usr/bin/env bash
# review-ok.sh — predicate: did this reviewer run finish with a review?
#
# Usage:
#   review-ok.sh <run-dir> [--explain]
#
# Exit 0 when the run recorded under <run-dir> finished AND succeeded:
#   - its `done` marker says `status=ok` and its review (meta's `out=`, else
#     `review.md`) is non-empty, or
#   - for records written before `status=` existed: `exit=0` (or no exit line)
#     and a non-empty `review.md`.
# Exit 1 otherwise: still running, abandoned, failed, or produced no review.
#
# Use it wherever you pick "the last review": as the baseline for a delta
# review, for workon's "already reviewed?" check, or before posting a review.
# review.sh records a run that hit the model's output token limit as
# `status=failed` + `reason=truncated`: a `done` marker beside an empty
# `review.md` is never a finished review.
#
# `--explain` prints the reason for a non-zero exit (quiet otherwise).
set -uo pipefail

dir="${1:?usage: review-ok.sh <run-dir> [--explain]}"
explain=0
[ "${2:-}" = "--explain" ] && explain=1
# A file inside the run dir (the review.md path) is accepted too.
[ -f "$dir" ] && dir="$(dirname "$dir")"

done_f="$dir/done"
# The review lives where meta's `out=` says (a run spawned with --out),
# else in the run dir.
review="$(sed -n 's/^out=//p' "$dir/meta" 2>/dev/null | head -n 1)"
[ -n "$review" ] || review="$dir/review.md"

no() { if [ "$explain" -eq 1 ]; then echo "$1" >&2; fi; exit 1; }
# First value of KEY in the done marker, if any.
kv() { sed -n "s/^$1=//p" "$done_f" 2>/dev/null | head -n 1; }

[ -f "$done_f" ] || no "no done marker (running, abandoned, or not a run dir): $dir"

status="$(kv status)"
if [ -n "$status" ]; then
  [ "$status" = "ok" ] || no "status=$status reason=$(kv reason)"
  [ -s "$review" ] || no "status=ok but review.md is empty"
  exit 0
fi

# Record from before `status=` existed: trust the exit code and the output.
exit_code="$(kv exit)"
if [ -n "$exit_code" ] && [ "$exit_code" != "0" ]; then
  no "exit=$exit_code"
fi
[ -s "$review" ] || no "review.md is empty"
exit 0
