#!/usr/bin/env bash
# last.sh — print the most recent N screenshots' descriptions as plain text.
#
# Usage:
#   last.sh            # print the most recent capture (path + description)
#   last.sh 3          # print the last 3 captures
#   last.sh --json     # print the last capture as a raw JSON line
#   last.sh 2 --json   # last 2 as JSON lines
#
# Env:
#   SCREENSHOT_DIR (default: /tmp/pi-screenshots)
set -euo pipefail
DIR="${SCREENSHOT_DIR:-/tmp/pi-screenshots}"
HIST="$DIR/history.jsonl"

COUNT="1"
AS_JSON=0
for a in "$@"; do
  case "$a" in
    --json) AS_JSON=1 ;;
    ''|*[!0-9]*) ;; # ignore non-numeric
    *) COUNT="$a" ;;
  esac
done

if [ ! -f "$HIST" ]; then
  echo "No screenshots in history yet ($HIST not found)." >&2
  exit 0
fi

if [ "$AS_JSON" = 1 ]; then
  tail -n "$COUNT" "$HIST"
else
  python3 - "$HIST" "$COUNT" <<'PY'
import json, sys
path, count = sys.argv[1], int(sys.argv[2])
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except FileNotFoundError:
    print("No screenshot history found.", file=sys.stderr); sys.exit(0)
recs = [json.loads(l) for l in lines if l.strip()]
for i, r in enumerate(recs[-count:], start=1):
    idx = len(recs) - count + i
    print(f"#{idx}  {r.get('ts','')}  {r.get('path','')}  [{r.get('model','')}]")
    print(r.get("description","").strip())
    print()
PY
fi
