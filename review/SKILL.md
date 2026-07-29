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

3. **Spawn the reviewer with the script.** Hand it your mandate file:
   ```bash
   scripts/review.sh --pr <NUM|branch|url> --prompt <mandate.md>
   # optionally pick a strong reasoning model:
   scripts/review.sh --pr 1390 --prompt /tmp/review.md --model z.ai/glm-5.2 --thinking high
   ```
   The script handles the tricky parts — detaching the subprocess, giving it
   `--approve` so tools actually run, capturing the real child PID, and telling
   you exactly how to poll. Read its `--help` for all flags.

4. **Monitor and surface the result.** Poll the output file (the script prints
   the path + a polling command). When the reviewer finishes, read the review to
   the user and, if asked, triage the findings into fix-now / discuss / dismiss.

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

- Trivial PRs (typo, one-line fix) — overhead isn't worth it.
- You need a *fast* gut-check — use a normal in-session read instead.
- The PR isn't yours and you haven't lost objectivity on it.

## Notes

- The reviewer runs **in the same repo/worktree** (inherits cwd) so it sees the
  real code and can run the real tests the CI way.
- Default model is pi's configured default. For adversarial review, prefer a
  strong reasoning model (`--thinking high`) — `o3-pro`, `opus`, `gemini-pro`,
  or `z.ai/glm-5.2` all work. Pass `--model <provider/id>`.
- Output is plain markdown; feed it back to the user verbatim or summarize it.
