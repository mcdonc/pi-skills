---
name: review
description: Spawn a fresh, isolated pi subprocess to adversarially review a GitHub PR or local branch diff. Use when you want a second opinion on your own change, have lost objectivity after working on a branch, or want a review not influenced by the decisions you made while writing it. The reviewer is a brand-new pi session (no shared conversation memory) that reads the real code and runs the real tests.
---

# review — fresh-eyes adversarial PR review

You (the agent) are NOT the reviewer. You **spawn a second pi instance** that does
the review. The point is independence: the reviewer shares none of your
conversation history, so it isn't anchored to your rationale, your discarded
ideas, or your blind spots. It gets the project's conventions (AGENTS.md) and
the real code, nothing else.

A review that finds nothing is a failed review. Coach the reviewer accordingly
(see the prompt template) and take its findings seriously — it will catch things
you can't see because you wrote them.

## Workflow

1. **Understand what's being reviewed.** Get the PR/diff context:
   ```bash
   gh pr view <NUM> --json title,body,baseRefName,headRefName,files   # for a PR
   gh pr diff <NUM> | head -200                                       # skim the diff
   git log --oneline main..HEAD                                       # local branch
   git diff main...HEAD --stat                                        # scope
   ```
   Read the changed files directly (the big ones, the security-sensitive ones).
   The goal is to know *what the change does* and *where its risk concentrates*
   so you can write PR-specific scrutiny points.

2. **Write a tailored review mandate.** Copy
   [`references/review-prompt.md`](references/review-prompt.md) as a framework
   and fill in the "Specific things to scrutinize" section with concrete,
   *this*-PR risk areas you identified in step 1. Cite file paths. This tailored
   mandate is the whole value of the skill — a generic "review this PR" prompt
   gets a generic review.

   **Speed matters too.** For PRs under a few hundred lines, paste the diff
   itself into the mandate — it saves the reviewer many orientation round-trips
   (git log, --stat, re-reading files you already read). The template also tells
   the reviewer not to re-run full suites (CI is authoritative); keep that
   instruction unless the PR's whole point is test behavior.
   For the second and later reviews of the same branch, write a **delta
   mandate** instead — see the **Delta reviews (round 2+)** section below.

3. **Spawn the reviewer with the script.** Hand it your mandate file:
   ```bash
   scripts/review.sh --pr <NUM|branch|url> --prompt <mandate.md>
   # optionally pick a strong reasoning model:
   scripts/review.sh --pr 1390 --prompt /tmp/review.md --model z.ai/glm-5.3 --thinking high
   ```
   The script handles the tricky parts — detaching the subprocess, giving it
   `--approve` so tools actually run, capturing the real child PID, and telling
   you exactly how to poll. Read its `--help` for all flags.

4. **Monitor and surface the result.** Poll the output file (the script prints
   the path + a polling command). When the reviewer finishes, read the review to
   the user and, if asked, triage the findings into fix-now / discuss / dismiss.

## Delta reviews (round 2+)

Round 2+ on the same branch is a **delta review**: scope the mandate to what
changed since the last review plus verification of its findings. A full
re-read of an already-reviewed tree wastes the round re-finding what is
already recorded. When the user says "delta review", "review again",
"/review <N> again", or "re-review since the last review", they mean this
section. If no finished review exists for the branch (no baseline to delta
from), run a full review instead.

Build the mandate as in Workflow steps 1–2, but:

1. Find the baseline — the newest finished review for this branch:
   ```bash
   url=$(git config --get remote.origin.url); url=${url%.git}; url=${url#*://}; url=${url#*:}
   slug="$(basename "$(dirname "$url")")/$(basename "$url")"
   branch=$(git branch --show-current)
   newest=$(for d in "$HOME/.pi/agent/reviews/$slug/$branch"/*/; do
     [ -f "$d/done" ] && echo "$d"
   done | tail -1)
   base=$(grep -oP '^head=\K[0-9a-f]+' "$newest/meta")
   ```
2. Copy the template and paste the scope block from
   [`references/delta-review-scope.md`](references/delta-review-scope.md)
   at the top, filling in `<base>`, the `<base>..HEAD` diff, and the prior
   run's `review.md`.
3. Right-size the spawn: `--thinking medium` is usually enough for a delta
   round; keep `high` for deltas touching auth/security surfaces.

A finished delta review records its head like any other run, so the workon
skill's ancestor check (post-review fix commits don't re-trigger review)
keeps working unchanged.

**Overlap, don't serialize.** The reviewer runs in the background by default.
Spawn it immediately after the first push — not after the PR body, changelog
entry, and everything else are written — then do those chores while it runs.
By the time the PR is presentable, the review is usually done. If you run
/review serially at the end, the fix is scheduling, not speed.

## Critical pitfalls (the script handles these — here so you understand why)

- **`--approve` is mandatory.** In print mode (`-p`), pi cannot prompt for tool
  approval, so without `--approve` it can't run `git`/`read`/`bash` and silently
  produces zero output while appearing to "run." The script always passes it.
- **Print mode buffers.** `pi -p` writes nothing until it's completely done.
  Don't read an empty output file as "failed" — check whether the **child PID**
  is still alive (the script gives you a polling command that does this).
- **Fresh session.** The reviewer is a new `pi -p` invocation, so it has no
  conversation memory. It does still load project context (AGENTS.md, skills) so
  it knows the project's conventions and how to run tests — that's desirable.
  For a truly blind review pass `--no-context-files --no-skills` (see `--help`).
- **It's slow.** A real review makes many tool calls and reasons over a large
  diff. Minutes, not seconds. Background it (the default) and poll.

## When NOT to use this

- **Small diffs (< ~50 changed lines) with no security/behavior surface** — a
  typo, a one-line fix, a docs tweak. An in-session critical re-read (read the
  diff yourself as if a stranger wrote it) replaces the subprocess; the
  spawn + orientation overhead exceeds the review itself.
- You need a *fast* gut-check — use a normal in-session read instead.
- The PR isn't yours and you haven't lost objectivity on it.

## Notes

- The reviewer runs **in the same repo/worktree** (inherits cwd) so it sees the
  real code and can run the real tests.
- Default model is pi's configured default, `--thinking high`. **Right-size
  both.** `high` + a strong reasoning model (`o3-pro`, `opus`, `gemini-pro`,
  `z.ai/glm-5.3`) is for auth/security surfaces, migrations, large refactors.
  For a typical scoped workon PR, `--thinking medium` (or a faster model)
  loses little and finishes much sooner. Pass `--model <provider/id>`.
- Output is plain markdown; feed it back to the user verbatim or summarize it.
- Every run is recorded under `~/.pi/agent/reviews/<repo>/<branch>/<ts>/`
  (`meta`, the mandate, `review.md`, `pid`, `done`). Past reviews stay
  discoverable there, and the `worktree-indicator` footer extension reads these
  records to show `review ✓/◌/✗` for the branch you're working in. Override the
  location with `PI_REVIEWS_DIR`.
