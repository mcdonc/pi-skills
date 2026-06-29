#!/usr/bin/env bash
# describe.sh — describe a screenshot using a vision-capable model.
#
# Spawns a throwaway `pi` subprocess in print mode with a vision model so the
# main (possibly text-only) model can "see" the image. The description is
# printed to stdout and appended to a JSONL history so callers like
# "compare to the last screenshot" can reference prior captures.
#
# Usage:
#   describe.sh <image.png>                   # default prompt + default model
#   describe.sh <image.png> "<prompt>"         # custom prompt
#   VISION_MODEL=z-ai/glm-4.6v describe.sh ... # override model
#
# Env:
#   VISION_MODEL   (default: z-ai/glm-5v-turbo)
#   SCREENSHOT_DIR (default: /tmp/pi-screenshots)
#   PI_BIN         (default: pi)  — set to a full path if pi isn't on PATH here
set -euo pipefail

IMG="${1:?usage: describe.sh <image.png> [prompt]}"
PROMPT="${2:-Describe what is visible on this screen. Be concrete: list UI elements, open windows, any text or code shown, and overall layout. Keep it under ~150 words.}"

MODEL="${VISION_MODEL:-z-ai/glm-5v-turbo}"
DIR="${SCREENSHOT_DIR:-/tmp/pi-screenshots}"
PI="${PI_BIN:-pi}"
# Long-side target for downscaling the image before sending to the vision model.
# Set to 0 or empty to skip resizing. Image tokens scale with pixel area, so
# this is the main cost lever for the vision call.
SCALE="${VISION_IMAGE_SCALE:-1920}"
mkdir -p "$DIR"

if [ ! -f "$IMG" ]; then
  echo "describe.sh: image not found: $IMG" >&2
  exit 1
fi

# Resolve pi to an absolute path if it is on PATH (subshells may have a minimal PATH).
if ! command -v "$PI" >/dev/null 2>&1; then
  if command -v pi >/dev/null 2>&1; then PI="$(command -v pi)"; fi
fi

# Downscale the image (long side = SCALE) to cut vision tokens. Best-effort:
# if no resizer is available, fall back to the original image.
DESCRIBE_IMG="$IMG"
if [ -n "${SCALE:-}" ] && [ "${SCALE:-0}" != "0" ]; then
  RESIZER=""
  if command -v convert >/dev/null 2>&1; then RESIZER="convert"
  elif command -v mogrify >/dev/null 2>&1; then RESIZER="mogrify"
  fi
  if [ -n "$RESIZER" ]; then
    SCALED="$DIR/.scaled-$(basename "$IMG")"
    if [ "$RESIZER" = "convert" ]; then
      convert "$IMG" -resize "${SCALE}x${SCALE}" "$SCALED" 2>/dev/null || SCALED=""
    else
      cp "$IMG" "$SCALED" && mogrify -resize "${SCALE}x${SCALE}" "$SCALED" 2>/dev/null || SCALED=""
    fi
    [ -n "$SCALED" ] && [ -s "$SCALED" ] && DESCRIBE_IMG="$SCALED"
  fi
fi

# Ask the vision model to read the (possibly downscaled) image and describe it.
DESC="$("$PI" -p --no-session --no-skills --model "$MODEL" \
  "Use the read tool to read this image: $DESCRIBE_IMG

Then answer:
$PROMPT

Output only the answer, no preamble." 2>/dev/null)"

# Append to JSONL history (one JSON object per line).
TS="$(date -Iseconds 2>/dev/null || date)"
TS_MS="$(date +%s%3N 2>/dev/null || date +%s)"
LINE="$(printf '%s' "$DESC" | tr -d '\r')"
# Build compact JSON, escaping the description text.
JSON_DESC="$(printf '%s' "$LINE" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')"
printf '{"ts":"%s","ts_ms":%s,"path":%s,"model":"%s","description":%s}\n' \
  "$TS" "${TS_MS:-0}" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$IMG")" \
  "$MODEL" "$JSON_DESC" >> "$DIR/history.jsonl"

printf '%s' "$DESC"
