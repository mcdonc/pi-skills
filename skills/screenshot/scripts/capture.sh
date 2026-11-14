#!/usr/bin/env bash
# capture.sh — capture the left monitor to a timestamped PNG.
#
# Usage:
#   capture.sh                 # default: import -window root -crop 3840x2160+0+0 <out>
#   capture.sh <out.png>       # explicit output path
#   CAPTURE_ARGS="..." capture.sh   # override the -crop geometry etc.
#
# Honors:
#   CAPTURE_BIN   (default: import)
#   CAPTURE_ARGS  (default: -crop 3840x2160+0+0)
#   SCREENSHOT_DIR(default: /tmp/pi-screenshots)
set -euo pipefail

BIN="${CAPTURE_BIN:-import}"
GEOMETRY="${CAPTURE_ARGS:--crop 3840x2160+0+0}"
DIR="${SCREENSHOT_DIR:-/tmp/pi-screenshots}"
MAX_AGE_DAYS="${SCREENSHOT_MAX_AGE_DAYS:-3}"
mkdir -p "$DIR"

# Opportunistic cleanup: remove screenshot PNGs older than MAX_AGE_DAYS.
# Runs on every capture; silent and best-effort (never fails the capture).
if [ -d "$DIR" ]; then
  find "$DIR" -maxdepth 1 -name 'screenshot-*.png' -type f -mtime +"$MAX_AGE_DAYS" -delete 2>/dev/null || true
fi

# Prune history.jsonl of entries older than MAX_AGE_DAYS so it doesn't
# reference deleted files. Best-effort; needs python3.
HIST="$DIR/history.jsonl"
if [ -f "$HIST" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$HIST" "$MAX_AGE_DAYS" <<'PY' 2>/dev/null || true
import json, os, sys, time
path, days = sys.argv[1], int(sys.argv[2])
cutoff_ms = (time.time() - days * 86400) * 1000
kept = []
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            ts_ms = rec.get("ts_ms") or 0
            if ts_ms and ts_ms >= cutoff_ms:
                kept.append(line)
            # Drop entries whose image is gone, regardless of age.
            elif rec.get("path") and not os.path.exists(rec["path"]):
                continue
            else:
                kept.append(line)
except FileNotFoundError:
    sys.exit(0)
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(kept))
    if kept:
        f.write("\n")
PY
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$DIR/screenshot-$TS.png}"

# Wayland: X11 grabbers (import, x11grab) capture nothing — the XWayland root
# window holds no compositor content. Use spectacle (KDE) when available, then
# crop to the requested geometry with magick. grim is wlroots-only, not KWin.
if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v spectacle >/dev/null 2>&1; then
  TMP="$(mktemp --suffix=.png)"
  spectacle -b -n -f -o "$TMP" || { rm -f "$TMP"; echo "spectacle capture failed" >&2; exit 1; }
  if [ -n "$GEOMETRY" ]; then
    GEO_ONLY="${GEOMETRY#-crop }"
    magick "$TMP" -crop "$GEO_ONLY" +repage "$OUT" || { cp "$TMP" "$OUT"; }
  else
    mv "$TMP" "$OUT"
  fi
  rm -f "$TMP"
  echo "$OUT"
  exit 0
fi

if [ -n "$GEOMETRY" ]; then
  "$BIN" -window root $GEOMETRY "$OUT"
else
  "$BIN" -window root "$OUT"
fi

echo "$OUT"
