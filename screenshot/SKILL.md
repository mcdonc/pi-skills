---
name: screenshot
description: Capture the left monitor and interpret it with a vision-capable GLM model. Use when the user says /screenshot or asks to screenshot the screen and act on what's shown (compare, read text, answer about, etc.).
---

# Screenshot skill

Capture the user's left monitor, have a **vision-capable model** describe it (the
main model may be text-only and cannot see images itself), then continue with the
user's request using that description.

The main model never switches — it delegates the single "seeing" step to a
throwaway vision subprocess via the helper scripts, then reasons over the result.

## Commands

- `capture.sh [out.png]` — capture the left monitor. Prints the output path.
  Default capture command:
  `import -window root -crop 3840x2160+0+0 <out>`
  Override geometry via `CAPTURE_ARGS=...`, or the whole binary via `CAPTURE_BIN=...`.
- `describe.sh <image.png> [prompt]` — describe an image with a vision model.
  Prints the description and appends a record to the history file.
  Override the model with `VISION_MODEL=z-ai/glm-5v-turbo` (or `z-ai/glm-4.6v`).
- `last.sh [N] [--json]` — print the most recent N descriptions from history
  (default 1). Use this for "compare to the last screenshot".

History: `$SCREENSHOT_DIR/history.jsonl` (default `/tmp/pi-screenshots/history.jsonl`),
one JSON object per line: `{ts, path, model, description}`.

All scripts are in this skill's `scripts/` directory. Use the directory of this
SKILL.md file as the base for relative paths. For example, if this skill is at
`~/.pi/agent/skills/screenshot/SKILL.md`, run `~/.pi/agent/skills/screenshot/scripts/capture.sh`.

## Workflow

When the user runs `/screenshot <further command>` (or asks equivalently):

1. **Capture** the left monitor:
   ```bash
   <skill_dir>/scripts/capture.sh
   ```
   It prints the path to the new screenshot, e.g. `/tmp/pi-screenshots/screenshot-20260627-065500.png`.

2. **Describe** that screenshot with the vision model:
   ```bash
   <skill_dir>/scripts/describe.sh "<printed path>"
   ```
   This prints the vision model's description of the screen.

3. If the user's request references a previous screenshot (e.g. "compare to the
   last screenshot"), fetch prior descriptions:
   ```bash
   <skill_dir>/scripts/last.sh 2   # last 2 captures as text
   ```

4. **Carry out the user's `<further command>`** using the description(s) above
   as the source of truth for what is/was on screen. You (the main model) stay
   in charge — the vision subprocess only supplies the description.

## Notes

- The vision call costs real tokens (see the model's pricing). One description
  per screenshot is enough; don't re-describe the same image repeatedly.
- If the user only wants the screenshot file with no interpretation, run just
  `capture.sh` and report the path.
- If capture fails (`import` not found / X permissions), report the error
  verbatim; don't try to interpret a missing image.
