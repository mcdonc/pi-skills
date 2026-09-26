# Delta review scope (round 2+)

> For the second and later reviews of the same branch. Copy the scope block
> below into the mandate — after the `# Task: Adversarial code review`
> heading, before `## What to review` — and fill in every placeholder:
>
> - `<base>` — the last reviewed commit (the `head=` line of the newest
>   finished run's `meta` for this branch).
> - The delta diff — `git diff <base>..HEAD`, pasted in. Mandatory: it saves
>   the reviewer its orientation round-trips. If it exceeds a few hundred
>   lines, paste the `--stat` plus the hot files and tell the reviewer to
>   fetch the rest itself.
> - The prior review — the previous run's `review.md`, pasted in whole.

---

## Scope — DELTA review, not a full review

This branch was fully reviewed at commit `<base>`. Review ONLY:

1. **The delta below** (`git diff <base>..HEAD`) — the fixes and any new
   code added since that review.
2. **Verification of the prior review's findings** (pasted below). For each
   blocking and important finding, confirm it is actually fixed in the tree
   and cite how (file:line). "The diff touches that file" is not enough —
   read the resulting code as it now stands.
3. **Regression bleed** — the places where the delta touches code the prior
   review already passed. Do not re-review unchanged code.

A fix that claims to fix a finding but does not is the most valuable thing
this review can catch — hunt for papered-over fixes.

### Delta diff (`<base>..HEAD`)

<!-- paste the diff here -->

### Prior review to verify

<!-- paste the previous review.md here -->

---
