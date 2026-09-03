#!/usr/bin/env bash
# review.sh — spawn a fresh, isolated pi subprocess to adversarially review a
# GitHub PR or a local branch diff.
#
# Usage:
#   review.sh --pr <NUM|branch|url> --prompt <mandate.md>
#             [--model <provider/id>] [--thinking <level>]
#             [--blind] [--worktree <dir>] [--out <file>] [--foreground]
#             [--pi <path>]
#
#   --pr          WHAT to review. One of:
#                   - PR number (e.g. 1390)           -> resolves repo + branch via gh
#                   - PR URL (github.com/.../pull/N)  -> parsed to number
#                   - git branch name (e.g. feature-x)-> reviews main...<branch> diff
#                   - "local"                         -> reviews main...HEAD diff
#   --prompt      Path to the review mandate (markdown). Required. The agent is
#                 expected to have tailored references/review-prompt.md for the PR.
#   --model       pi model as provider/id (default z.ai/glm-5.3; e.g.
#                 z.ai/glm-5.3, openai/o3-pro).
#                 Defaults to pi's configured default.
#   --thinking    off|minimal|low|medium|high|xhigh (default: high).
#   --blind       Pass --no-context-files --no-skills so the reviewer has NO
#                 project context — a truly blind read of the diff alone. By
#                 default the reviewer loads AGENTS.md + skills (knows how tests
#                 are run, conventions, etc.) which is usually what you want.
#   --worktree    Directory to run in (defaults to cwd). Use to point the
#                 reviewer at a worktree where the branch is checked out.
#   --out         Output file for the review (default: a temp file, printed below).
#   --foreground  Wait for completion and stream output inline (blocks).
#                 Default: background (detach) and return immediately with
#                 polling instructions.
#   --pi          Path to the pi binary (default: first of $PI_BIN, then `pi`).
#
# The script does NOT write the mandate — the caller (the agent) produces a
# tailored review prompt. This script just spawns the reviewer correctly.
#
# The script also records the run under ~/.pi/agent/reviews/<repo>/<branch>/<ts>/
# (meta, mandate, review.md, pid, done) so the worktree-indicator footer
# extension can show "has this branch been reviewed?". Override with
# $PI_REVIEWS_DIR.
#
# CRITICAL: print mode (-p) cannot prompt for tool approval, so without --approve
# pi can't run git/read/bash and silently emits nothing while appearing to run.
# This script ALWAYS passes --approve. Don't "optimize" it away.
set -uo pipefail

# Stable per-repo directory key for the review record: the origin remote's
# owner/repo, falling back to the checkout's directory name. Must stay in sync
# with repoSlug() in extensions/worktree-indicator.ts.
repo_slug() {
  local dir="$1" url base owner
  url="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
  if [ -n "$url" ]; then
    url="${url%.git}"
    url="${url#*://}"   # strip scheme:// (https://, ssh://, ...)
    url="${url#*:}"     # strip scp-style host (git@host:)
    base="${url##*/}"
    owner="${url%"$base"}"; owner="${owner%/}"; owner="${owner##*/}"
    if [ -n "$owner" ] && [ -n "$base" ]; then
      printf '%s/%s' "$owner" "$base"
      return 0
    fi
  fi
  git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  basename "$(git -C "$dir" rev-parse --show-toplevel)"
}

PR=""
PROMPT=""
MODEL="z.ai/glm-5.3"
THINKING="high"
BLIND=0
WORKTREE=""
OUT=""
FOREGROUND=0
PI_BIN="${PI_BIN:-pi}"

usage() { sed -n '2,42p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)         PR="$2"; shift 2 ;;
    --prompt)     PROMPT="$2"; shift 2 ;;
    --model)      MODEL="$2"; shift 2 ;;
    --thinking)   THINKING="$2"; shift 2 ;;
    --blind)      BLIND=1; shift ;;
    --worktree)   WORKTREE="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --foreground) FOREGROUND=1; shift ;;
    --pi)         PI_BIN="$2"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "review.sh: unknown argument '$1'" >&2; usage 2 ;;
  esac
done

[ -n "$PR" ]     || { echo "review.sh: --pr is required (number, URL, branch, or 'local')" >&2; exit 2; }
[ -n "$PROMPT" ] || { echo "review.sh: --prompt <mandate.md> is required" >&2; exit 2; }
[ -f "$PROMPT" ] || { echo "review.sh: prompt file not found: $PROMPT" >&2; exit 2; }

command -v "$PI_BIN" >/dev/null 2>&1 || {
  echo "review.sh: pi binary not found ('$PI_BIN'). Install pi or set --pi / \$PI_BIN." >&2
  exit 1
}

[ -n "$WORKTREE" ] || WORKTREE="$PWD"
[ -d "$WORKTREE" ] || { echo "review.sh: worktree dir not found: $WORKTREE" >&2; exit 1; }
git -C "$WORKTREE" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "review.sh: not a git repository: $WORKTREE" >&2; exit 1;
}

# --- Resolve WHAT to review into a concrete description for the reviewer ---
WHAT="$PR"
SUBJECT="$PR"
if [ "$PR" = "local" ]; then
  WHAT="the diff between the default branch and HEAD"
  SUBJECT="local diff (HEAD vs default branch)"
elif echo "$PR" | grep -qE '^[0-9]+$'; then
  WHAT="PR #$PR"
  # try to enrich with title for the log line only
  if command -v gh >/dev/null 2>&1; then
    TITLE="$(gh pr view "$PR" --json title -q .title 2>/dev/null || true)"
    [ -n "$TITLE" ] && SUBJECT="PR #$PR — $TITLE"
  fi
elif echo "$PR" | grep -qE 'github\.com/.*/pull/[0-9]'; then
  NUM="$(echo "$PR" | grep -oE '[0-9]+$')"
  WHAT="PR #$NUM"
  SUBJECT="PR #$NUM"
else
  # treat as branch name
  WHAT="the diff between the default branch and branch '$PR'"
  SUBJECT="branch $PR (vs default branch)"
fi

# --- Review record (persistent, for the footer indicator) ---
# Record under the branch BEING REVIEWED, not the checkout's current branch:
# PR reviews are typically launched from the main checkout (cwd on `main`),
# while the footer indicator keys records by the worktree's branch. For a
# PR number/URL, ask gh for the head branch + sha; for a branch name, resolve
# it in git directly; for "local", the checkout branch is correct.
PI_REVIEWS_DIR="${PI_REVIEWS_DIR:-$HOME/.pi/agent/reviews}"
REVIEW_BRANCH=""
REVIEW_HEAD=""
if echo "$PR" | grep -qE '^[0-9]+$|github\.com/.*/pull/[0-9]'; then
  NUM="$(echo "$PR" | grep -oE '[0-9]+$')"
  PRJSON="$(gh pr view "$NUM" --json headRefName,headRefOid 2>/dev/null || true)"
  REVIEW_BRANCH="$(echo "$PRJSON" | jq -r '.headRefName // empty' 2>/dev/null || true)"
  REVIEW_HEAD="$(echo "$PRJSON" | jq -r '.headRefOid // empty' 2>/dev/null || true)"
elif [ "$PR" != "local" ]; then
  REVIEW_BRANCH="$PR"
  REVIEW_HEAD="$(git -C "$WORKTREE" rev-parse --verify "$PR^{commit}" 2>/dev/null || true)"
fi
[ -n "$REVIEW_BRANCH" ] || REVIEW_BRANCH="$(git -C "$WORKTREE" branch --show-current 2>/dev/null || true)"
[ -n "$REVIEW_HEAD" ] || REVIEW_HEAD="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"
[ -n "$REVIEW_BRANCH" ] || REVIEW_BRANCH="detached"
BRANCH_AT_LAUNCH="$REVIEW_BRANCH"
BRANCH_SLUG="${BRANCH_AT_LAUNCH//\//-}"
REPO_SLUG="$(repo_slug "$WORKTREE" || true)"
[ -n "$REPO_SLUG" ] || REPO_SLUG="unknown"
HEAD_SHA="$REVIEW_HEAD"
STARTED="$(date +%s)"
RUN_DIR="$PI_REVIEWS_DIR/$REPO_SLUG/$BRANCH_SLUG/$STARTED"
mkdir -p "$RUN_DIR"
{
  echo "repo=$REPO_SLUG"
  echo "branch=$BRANCH_AT_LAUNCH"
  echo "pr=$PR"
  echo "subject=$SUBJECT"
  echo "model=$MODEL"
  echo "thinking=$THINKING"
  echo "head=$HEAD_SHA"
  echo "started=$STARTED"
  echo "worktree=$WORKTREE"
} > "$RUN_DIR/meta"

# --- Output file ---
# Default lives inside the run dir so past reviews are discoverable later.
[ -n "$OUT" ] || OUT="$RUN_DIR/review.md"
: > "$OUT"   # truncate so a stale prior run can't masquerade as this one
ERR="${OUT%.md}.err.log"
: > "$ERR"
echo "out=$OUT" >> "$RUN_DIR/meta"

# --- Build the pi invocation ---
# NOTE on isolation flags:
#   --no-session   ephemeral: don't persist this review as a saved session
#   --approve      REQUIRED for -p mode to use tools (no prompt possible)
#   --thinking     high for deep adversarial reasoning over a diff
ARGS=(-p --no-session --approve --thinking "$THINKING" --name "review: $SUBJECT")
[ -n "$MODEL" ] && ARGS+=(--provider "${MODEL%%/*}" --model "${MODEL#*/}")
[ "$BLIND" -eq 1 ] && ARGS+=(--no-context-files --no-skills)

# Prepend the review framing to the mandate. Keep it short — the mandate file
# is where the real scrutiny points live.
PREAMBLE="# Review target
You are reviewing: ${WHAT}

Follow the review instructions below. The cwd is the repo checkout — use your
tools to read the real code, run git, and run the tests. Be adversarial: a
review that finds nothing is a failed review.

# Your mandate
"

( cat <<EOF
$PREAMBLE
EOF
  cat "$PROMPT"
) > "$OUT.prompt"

launch() {
  # Detach fully from the controlling terminal so the parent shell exiting never
  # kills the reviewer. setsid + </dev/null + disown.
  if [ "$FOREGROUND" -eq 1 ]; then
    ( cd "$WORKTREE" && "$PI_BIN" "${ARGS[@]}" "$(cat "$OUT.prompt")" \
        >"$OUT" 2>"$ERR" )
    rc=$?
    printf 'finished=%s\nexit=%s\n' "$(date +%s)" "$rc" > "$RUN_DIR/done"
    return "$rc"
  fi
  # Background: capture the REAL pi PID, not the wrapper bash PID. We write a
  # launcher script that contains the full argv baked in (avoids the
  # array-through-`bash -c "${@:3}"` quoting trap, which leaked the trailing
  # OUT/ERR/PIDFILE args into pi). setsid detaches it into its own session.
  PIDFILE="$(mktemp -t pr-review.pid.XXXXXX)"
  LAUNCHER="$(mktemp -t pr-review.launch.XXXXXX.sh)"
  {
    echo '#!/usr/bin/env bash'
    printf 'cd %q || exit 1\n' "$WORKTREE"
    # Build the pi command with %q-safe quoting, one arg per line, continuation.
    printf '%q \\
' "$PI_BIN"
    for a in "${ARGS[@]}"; do printf '  %q \\
' "$a"; done
    printf '  %q >%q 2>%q &\n' "$(cat "$OUT.prompt")" "$OUT" "$ERR"
    printf 'review_pid=$!\n'
    printf 'echo "$review_pid" > %q\n' "$PIDFILE"
    printf 'echo "pid=$review_pid" > %q\n' "$RUN_DIR/pid"
    # Wait (in this detached shell) and record completion for the indicator.
    printf 'wait "$review_pid"; rc=$?\n'
    printf 'printf "finished=%%s\\nexit=%%s\\n" "$(date +%%s)" "$rc" > %q\n' "$RUN_DIR/done"
  } > "$LAUNCHER"
  chmod +x "$LAUNCHER"
  setsid bash "$LAUNCHER" </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  # Give setsid a moment to spawn + write the pidfile.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$PIDFILE" ] && break
    sleep 0.3
  done
  REAL_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  rm -f "$PIDFILE"

  echo "Spawned reviewer for: $SUBJECT"
  echo "  cwd:      $WORKTREE"
  echo "  model:    ${MODEL:-pi default} (thinking=$THINKING, blind=$([ "$BLIND" -eq 1 ] && echo yes || echo no))"
  echo "  output:   $OUT"
  echo "  record:   $RUN_DIR"
  echo "  stderr:   $ERR"
  if [ -n "$REAL_PID" ]; then
    echo "  pid:      $REAL_PID"
    cat <<EOF

Poll (prints 'finished' when done, else 'running'):
  ps -p $REAL_PID >/dev/null && echo running || echo finished; tail -5 $OUT
EOF
  else
    echo "  pid:      (could not capture — poll the output file directly)"
    echo
    echo "Poll:"
    echo "  tail -5 $OUT"
  fi
  cat <<EOF

NOTE: pi -p buffers ALL output until it finishes — an empty output file with a
running pid is NORMAL, not a failure. Wait (reviewers take minutes), then check.
EOF
}

launch
