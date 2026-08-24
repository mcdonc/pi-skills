---
name: review-slop
description: Deep-review a single auto-closed/reopened GitHub issue or PR for slop. Pulls the item's full context (description, comments, PR diff, author trust, cited file paths checked against the real repo) and computes a 0-100 slop score, then recommends reopen-and-act / keep-closed / needs-more-info with evidence. Use when the user says /review-slop <#> or asks to assess a specific issue/PR's legitimacy.
---

# Review-slop skill

Assess a single GitHub issue or PR that the default-closed policy auto-closed (or
that surfaced in the triage queue) and decide whether it deserves attention. The
script gathers every cheap signal and a heuristic score; **you** (the model)
read the evidence and write the recommendation.

## Command

- `review-slop.sh [--repo OWNER/NAME] <ISSUE_OR_PR_NUMBER|URL>` — fetch + score,
  emit JSON.

`<NUMBER>` may be a bare number (`1042`) or a full URL. `--repo` defaults to the
repo of the current working directory.

The skill directory is the one containing this `SKILL.md`, e.g.
`~/.pi/agent/skills/review-slop`.

## Invocation

This skill registers as `/skill:review-slop`. Example requests:

- `/skill:review-slop 1042`
- `/skill:review-slop https://github.com/mcdonc/klangk/issues/1042`
- `assess issue 1042 — is this slop?`

## Workflow

When the user runs `/skill:review-slop <#>` (or asks equivalently):

### 1. Fetch and score

```bash
<skill_dir>/scripts/review-slop.sh <#> [--repo OWNER/NAME]
```

Read the JSON. Key fields:

- `score.score` (0–100, **higher = more likely legitimate**) and `score.components`
  (`trust`/`substance`/`grounding`/`template`, each with its max).
- `score.reasons` — the concrete signals behind the score, in priority order.
- `score.checked_grounding` — `false` means grounding was skipped (no local repo
  checkout); treat the `grounding` component as neutral, not as evidence.
- `author` — `login`, `account_age_days`, `prior_contributions`, `is_allowlisted`.
- `body`, `body_len`, `comments` (author + body each), `cited_paths`.
- `pr_files` — the changed file paths (PRs only); real evidence of work.
- `labels`, `state`, `url`, `kind` (`issue`|`pr`).

### 2. Reason over the evidence (your job)

The score is a **starting heuristic, not a verdict**. You may adjust the item's
effective score by up to ±10 with a stated reason — e.g. the body is short but
the single sentence is precisely on point (raise), or it's long but says nothing
substantive (lower). Weigh:

- **Substantive?** Does it describe a real problem/change with specifics (repro
  steps, affected behavior, what changes and why)?
- **Grounded?** Do the cited file paths / symbols actually exist in the repo?
  Hallucinated paths are a strong slop signal. (Only meaningful when
  `checked_grounding` is true.)
- **Trustworthy author?** Allowlisted, or aged account with prior contributions?
  A brand-new account with zero history is not damning alone but compounds.
- **For PRs:** does the diff match the description? A large diff with a one-line
  body, or a body describing files the diff doesn't touch, is suspicious.

### 3. Recommend one of

- **reopen-and-act** — genuine contribution; worth maintainer time. (Use the
  `/reopen <#>` skill to apply, optionally trusting the author.)
- **keep-closed** — low-signal / not actionable as written. (Use `/keep-closed
  <#>` to apply.)
- **needs-more-info** — plausibly real but underspecified; reply asking for the
  missing piece (repro, affected version, what they tried) before deciding.

### 4. Report back

Give the user a compact summary: the score with its components, the 2–3 reasons
that drove it, your adjustment (if any) and why, and the recommendation with a
one-sentence justification + the item URL. Quote any damning or exonerating
detail verbatim (a hallucinated path, a precise repro).

## Notes

- **Grounding needs a checkout.** Run from within a clone of the target repo for
  the file-path verification; otherwise `grounding` is neutral (8/25) and
  `checked_grounding` is false. The checkout's local HEAD must be current — a
  stale checkout may mark real paths as "not found".
- The score weights are isolated in `slop-common/score.sh`; they're tunable over
  time from keep-closed-vs-promoted outcomes.
- The script only reads (gh api / gh view); it changes nothing on GitHub.
