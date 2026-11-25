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
#   --model       pi model as provider/id (e.g. z.ai-3/glm-5.3, openai/o3-pro).
#                 Default: the invoking session's active model — pi exports
#                 PI_PROVIDER/PI_MODEL to its subprocesses, so a review spawned
#                 from an agent session runs on the same provider+model as that
#                 session. Outside a pi session, falls back to pi's configured
#                 default. An explicit --model always overrides.
#   --thinking    off|minimal|low|medium|high|xhigh (default: high).
#   --blind       Pass --no-context-files --no-skills so the reviewer has NO
#                 project context — a truly blind read of the diff alone. By
#                 default the reviewer loads AGENTS.md + skills (knows how tests
#                 are run, conventions, etc.) which is usually what you want.
#   --worktree    Directory to run in (defaults to cwd). Use to point the
#                 reviewer at a worktree where the branch is checked out.
#   --out         Output file for the review (default: <record dir>/review.md,
#                 printed below).
#   --foreground  Wait for completion and stream output inline (blocks).
#                 Default: background (detach) and return immediately with
#                 polling instructions.
#   --pi          Path to the pi binary (default: first of $PI_BIN, then `pi`).
#
#   review.sh --status <run-dir | review.md>
#
#   --status      Report on a run this script spawned: prints `running`/`starting`
#                 (exit 3), `finished` (exit 0), or `FAILED:` with the reason and a
#                 retry hint (exit 1). Takes the `record:` dir or any file
#                 inside it. Exit 2 when it is not a review record, or when
#                 review-ok.sh is not next to this script.
#
# The script does NOT write the mandate — the caller (the agent) produces a
# tailored review prompt. This script just spawns the reviewer correctly.
#
# The script also records the run under ~/.pi/agent/reviews/<repo>/<branch>/<ts>/
# (meta, the mandate as review.md.prompt, review.md, review.err.log, pid, done)
# so the worktree-indicator footer
# extension can show "has this branch been reviewed?". `done` carries
# status=ok|failed plus a reason: a run that produced no review (the model hit
# its output token limit, pi crashed, ...) is status=failed, never a finished
# review. Override the location with $PI_REVIEWS_DIR.
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
MODEL=""
MODEL_SOURCE="explicit"
THINKING="high"
BLIND=0
WORKTREE=""
OUT=""
FOREGROUND=0
PI_BIN="${PI_BIN:-pi}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_TARGET=""

# Usage is the leading comment block (everything above the first code line).
usage() { sed -n '2,/^[^#]/p' "$0" | sed '$d'; exit "${1:-0}"; }

# Write the `done` marker for a finished run. status=ok only when pi exited 0
# AND wrote a review; anything else is status=failed with a reason, so no
# reader (review-ok.sh, workon's check, the footer) mistakes a run that
# produced nothing for a finished review. Pi reports a `length` stop as
# `Response was truncated: the model reached its output token limit.` and
# exit 1; a reasoning model can spend the whole output budget thinking, so
# review.md is empty. Written via a temp file + mv: a half-written marker
# (finished= without exit=) would read as success. The temp name is unique so
# two launchers that share a run dir cannot interleave their writes.
finish_run() {
  local run_dir="$1" out="$2" err="$3" rc="$4"
  local status="ok" reason="" tmp
  if [ "$rc" -ne 0 ]; then
    status="failed"
    if grep -qs 'output token limit' "$err"; then reason="truncated"; else reason="error"; fi
  elif [ ! -s "$out" ]; then
    status="failed"
    reason="empty"
  fi
  tmp="$(mktemp "$run_dir/.done.XXXXXX" 2>/dev/null)" || tmp="$run_dir/.done.tmp"
  {
    printf 'finished=%s\nexit=%s\nstatus=%s\n' "$(date +%s)" "$rc" "$status"
    if [ -n "$reason" ]; then printf 'reason=%s\n' "$reason"; fi
  } > "$tmp" && mv -f "$tmp" "$run_dir/done"
}

# Seconds the process has been running, from ps etime ([[dd-]hh:]mm:ss);
# prints nothing when the pid is gone. 10# keeps leading zeros decimal.
ps_etime_s() {
  local e d=0 h=0 m=0 s a="" b="" c=""
  e="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$e" ] || return 1
  e="${e%%.*}"   # Darwin prints mm:ss.ss
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  IFS=: read -r a b c <<<"$e"
  case "$e" in *:*:*) h="$a"; m="$b"; s="$c" ;; *:*) m="$a"; s="$b" ;; *) s="$a" ;; esac
  echo $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# Print one verdict for a recorded run and return its state:
#   0  finished — a review was produced
#   1  failed   — the done marker says so (reason=truncated|empty|error), or the
#                 reviewer is gone and no done marker was ever written
#   2  not a review record, or review-ok.sh is not next to this script
#   3  running  — no done marker yet and the reviewer pid is alive (or the run
#                 just started and has no pid on file yet)
# Takes the run dir or any file inside it (the review.md path, for example).
print_status() {
  local target="$1" run_dir out err subject model thinking pid reason started age bytes tag exit_code partial et
  if [ -f "$target" ]; then run_dir="$(dirname "$target")"; else run_dir="${target%/}"; fi
  if [ ! -f "$run_dir/meta" ]; then
    echo "review.sh: not a review record (no meta file): $run_dir" >&2
    return 2
  fi
  if [ ! -x "$SCRIPT_DIR/review-ok.sh" ]; then
    echo "review.sh: $SCRIPT_DIR/review-ok.sh is missing; keep the skill's scripts together" >&2
    return 2
  fi
  kv_meta() { sed -n "s/^$1=//p" "$run_dir/meta" | head -n 1; }
  out="$(kv_meta out)"; [ -n "$out" ] || out="$run_dir/review.md"
  err="${out%.md}.err.log"
  subject="$(kv_meta subject)"
  model="$(kv_meta model)"
  thinking="$(kv_meta thinking)"
  tag="$subject [${model:-pi default}${thinking:+, thinking=$thinking}]"

  if [ ! -f "$run_dir/done" ]; then
    pid="$(sed -n 's/^pid=//p' "$run_dir/pid" 2>/dev/null | head -n 1)"
    started="$(kv_meta started)"
    age=$(( $(date +%s) - ${started:-0} ))
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      # The pid counts only while it is still THIS reviewer. pi rewrites its
      # process title to "pi", so the command line is no proof; its age is:
      # the reviewer was born within moments of `started`, a recycled pid was
      # born at an unrelated time.
      et="$(ps_etime_s "$pid" || echo -1)"
      if ps -o args= -p "$pid" 2>/dev/null | grep -qF -- "review: $subject" \
         || { [ "$et" -ge 0 ] && [ $((age - et)) -ge -5 ] && [ $((age - et)) -le 120 ]; }; then
        echo "running: $tag (pid $pid; print mode buffers all output until the end)"
        return 3
      fi
    fi
    if [ -z "$pid" ] && [ "$age" -lt 30 ]; then
      echo "starting: $tag (no pid on file yet; poll again shortly)"
      return 3
    fi
    echo "FAILED: $tag — the reviewer (pid ${pid:-unknown}) is gone and wrote no done marker. Re-spawn the review."
    return 1
  fi

  if "$SCRIPT_DIR/review-ok.sh" "$run_dir"; then
    bytes="$(wc -c <"$out" 2>/dev/null | tr -d ' ')"
    echo "finished: $tag — ${bytes:-?} bytes of review in $out"
    return 0
  fi

  exit_code="$(sed -n 's/^exit=//p' "$run_dir/done" | head -n 1)"
  reason="$(sed -n 's/^reason=//p' "$run_dir/done" | head -n 1)"
  # Records from before `reason=` existed: read the cause off pi's stderr.
  if [ -z "$reason" ] && grep -qs 'output token limit' "$err" 2>/dev/null; then reason="truncated"; fi
  partial=""
  [ -s "$out" ] && partial=" after writing only part of the review"
  echo "FAILED: $tag — no complete review was produced (reason=${reason:-unknown})."
  case "$reason" in
    truncated)
      cat <<EOF
The model hit its output token limit${partial}: its reasoning and its text
share the output budget, which it used up. Retry with a lower --thinking (was:
${thinking:-high}), another --model, or a larger maxTokens on the model's entry in
~/.pi/agent/models.json (pi sends 16384 when the entry omits it).
EOF
      ;;
    *)
      if [ "${exit_code:-0}" = "0" ]; then
        echo "pi exited 0 but wrote no complete review. Re-spawn; if it repeats, try another --model."
      else
        echo "pi exited non-zero (exit=$exit_code); its stderr is below."
      fi
      ;;
  esac
  if [ -n "$partial" ]; then
    echo "Partial output was kept in $out — readable, but the review is incomplete."
  fi
  if [ -s "$err" ]; then
    echo "stderr:"
    tail -n 5 "$err" | sed 's/^/  /'
  fi
  return 1
}

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
    --status)     [ $# -ge 2 ] || { echo "review.sh: --status needs the run dir (or a file inside it)" >&2; exit 2; }
                  STATUS_TARGET="$2"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "review.sh: unknown argument '$1'" >&2; usage 2 ;;
  esac
done

# --status only reports on an existing run: it needs no --pr/--prompt.
if [ -n "$STATUS_TARGET" ]; then
  print_status "$STATUS_TARGET"
  exit $?
fi

[ -n "$PR" ]     || { echo "review.sh: --pr is required (number, URL, branch, or 'local')" >&2; exit 2; }
[ -n "$PROMPT" ] || { echo "review.sh: --prompt <mandate.md> is required" >&2; exit 2; }
[ -f "$PROMPT" ] || { echo "review.sh: prompt file not found: $PROMPT" >&2; exit 2; }

# Default the reviewer's model to the invoking session's active model. pi
# exports PI_PROVIDER and PI_MODEL to the bash subprocesses it spawns, so the
# reviewer runs on the same provider+model as the agent that spawned it (a
# mid-session /model switch is picked up too), instead of pi's configured
# default. An explicit --model always overrides; outside a pi session (no
# PI_MODEL in the environment) the spawned pi uses its configured default.
if [ -z "$MODEL" ]; then
  if [ -n "${PI_MODEL:-}" ]; then
    case "$PI_MODEL" in
      */*) MODEL="$PI_MODEL" ;;
      *)   if [ -n "${PI_PROVIDER:-}" ]; then
             MODEL="$PI_PROVIDER/$PI_MODEL"
           else
             MODEL="$PI_MODEL"
           fi ;;
    esac
    MODEL_SOURCE="inherited from session (PI_PROVIDER/PI_MODEL)"
  else
    MODEL_SOURCE="pi configured default"
  fi
fi

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
# Two spawns in one second must not share a run dir, and the footer lists run
# dirs by their numeric name: claim the name with mkdir (atomic) and bump the
# timestamp on a collision instead of adding a suffix.
RUN_PARENT="$PI_REVIEWS_DIR/$REPO_SLUG/$BRANCH_SLUG"
mkdir -p "$RUN_PARENT"
while :; do
  RUN_DIR="$RUN_PARENT/$STARTED"
  mkdir "$RUN_DIR" 2>/dev/null && break
  STARTED=$((STARTED + 1))
done
{
  echo "repo=$REPO_SLUG"
  echo "branch=$BRANCH_AT_LAUNCH"
  echo "pr=$PR"
  echo "subject=$SUBJECT"
  echo "model=$MODEL"
  echo "model_source=$MODEL_SOURCE"
  echo "thinking=$THINKING"
  echo "head=$HEAD_SHA"
  echo "started=$STARTED"
  echo "worktree=$WORKTREE"
} > "$RUN_DIR/meta"

# --- Output file ---
# A relative --out would be written by the launcher under $WORKTREE but read
# by --status / review-ok.sh under the caller's cwd. Pin it to the caller's
# cwd now so every reader resolves the same file.
case "$OUT" in /*) ;; ?*) OUT="$PWD/$OUT" ;; esac
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
# --provider only makes sense when MODEL carries a provider/ prefix.
case "$MODEL" in
  */*) ARGS+=(--provider "${MODEL%%/*}" --model "${MODEL#*/}") ;;
  *)   ARGS+=(--model "$MODEL") ;;
esac
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
    # Background the subshell only to learn pi's real pid (exec makes the
    # subshell pi), so --status can tell running from abandoned here too.
    ( cd "$WORKTREE" && exec "$PI_BIN" "${ARGS[@]}" "$(cat "$OUT.prompt")" ) >"$OUT" 2>"$ERR" &
    fg_pid=$!
    echo "pid=$fg_pid" > "$RUN_DIR/pid"
    wait "$fg_pid"; rc=$?
    finish_run "$RUN_DIR" "$OUT" "$ERR" "$rc"
    print_status "$RUN_DIR"
    # Exit by the record's verdict, like --status: a run that produced no
    # review is a failure even when pi itself exited 0.
    if grep -q '^status=ok$' "$RUN_DIR/done"; then return 0; fi
    return 1
  fi
  # Background: capture the REAL pi PID, not the wrapper bash PID. We write a
  # launcher script that contains the full argv baked in (avoids the
  # array-through-`bash -c "${@:3}"` quoting trap, which leaked the trailing
  # OUT/ERR/PIDFILE args into pi). setsid detaches it into its own session.
  PIDFILE="$(mktemp -t pr-review.pid.XXXXXX)"
  LAUNCHER="$(mktemp -t pr-review.launch.XXXXXX.sh)"
  {
    echo '#!/usr/bin/env bash'
    # Copy finish_run in verbatim so the classification lives in one place.
    declare -f finish_run
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
    # Wait (in this detached shell) and classify the run for the indicator.
    printf 'wait "$review_pid"; rc=$?\n'
    printf 'finish_run %q %q %q "$rc"\n' "$RUN_DIR" "$OUT" "$ERR"
  } > "$LAUNCHER"
  chmod +x "$LAUNCHER"
  # setsid is a util-linux tool macOS does not ship; nohup covers the
  # same detach need (parent-exit immunity) when it is absent. Without
  # this fallback the spawn dies silently on macOS — the launcher never
  # runs, but the pre-created empty out/err files read as a live run.
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$LAUNCHER" </dev/null >/dev/null 2>&1 &
  else
    nohup bash "$LAUNCHER" </dev/null >/dev/null 2>&1 &
  fi
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
  echo "  model:    ${MODEL:-pi configured default} [$MODEL_SOURCE] (thinking=$THINKING, blind=$([ "$BLIND" -eq 1 ] && echo yes || echo no))"
  echo "  output:   $OUT"
  echo "  record:   $RUN_DIR"
  echo "  stderr:   $ERR"
  if [ -n "$REAL_PID" ]; then
    echo "  pid:      $REAL_PID"
  else
    echo "  pid:      (could not capture — the status command below does not need it)"
  fi
  cat <<EOF

Poll (prints 'running', 'finished', or 'FAILED: …' with the reason and a retry hint):
  $SCRIPT_DIR/$(basename "$0") --status $RUN_DIR

NOTE: pi -p buffers ALL output until it finishes — an empty output file with a
live pid is NORMAL, not a failure. --status tells running from failed.
EOF
}

launch
