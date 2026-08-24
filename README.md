# pi-skills

Personal **agent skills** (and pi **extensions**) for [pi](https://github.com/earendil-works/pi-coding-agent) (and any harness that implements the [Agent Skills](https://agentskills.io/specification) standard). These are general-purpose, `gh`-based, repo-agnostic tooling — they apply to any GitHub project, not just one.

This repo is **private** and personal; it's the version-controlled backup + shareable home for skills and extensions that otherwise live only on one machine.

Layout:

- `skills/` — the agent skills (each a `SKILL.md` + `scripts/`)
- `extensions/` — pi extensions (TypeScript, loaded from `~/.pi/agent/extensions/`)

## Live location / how pi loads these

The repo is cloned to `~/projects/pi-skills` and exposed to pi through two
directory symlinks — `~/.pi/agent/skills` → `skills/` and
`~/.pi/agent/extensions` → `extensions/`. Skills are discovered by scanning
that directory recursively for folders containing a `SKILL.md`, and
extensions are TypeScript modules auto-discovered and hot-reloadable — so
edits in the repo are live immediately, no build step.

Extensions live in `extensions/` and are loaded via a directory symlink:

```
ln -s ~/projects/pi-skills/extensions ~/.pi/agent/extensions
```

### Restore on a new machine

```bash
gh repo clone mcdonc/pi-skills ~/projects/pi-skills
ln -s ~/projects/pi-skills/skills ~/.pi/agent/skills
ln -s ~/projects/pi-skills/extensions ~/.pi/agent/extensions
cd ~/projects/pi-skills/extensions/zai-web-search && npm ci
```

That's it — pi picks up skills and extensions live from the repo; edits are
immediate, `/reload` hot-reloads extensions. (Requires `gh` and `jq` on
`PATH` for the skill scripts; the `screenshot` skill additionally needs a
vision-capable model configured.)

## Skill catalog

### GitHub operations

| Directory | Command | What it does |
|---|---|---|
| `skills/issue/` | `/issue <desc>` | Open a GitHub issue from a natural-language description (summarizes into title + body, files in the current repo or one named in the description). |
| `skills/address/` | `/address <PR#>` | Respond to PR review comments: detects unresolved threads, makes fixes in a worktree, pushes, posts replies, resolves threads. Re-runnable. |
| `skills/merge/` | `/merge <PR#>` | Merge a PR with `--admin` (bypasses merge protection), then cleans up the worktree and local/remote branches. |
| `skills/workon/` | `/workon <ISSUE#>` | Start work on an issue: creates a fresh git worktree off the default branch and prints the issue body. |
| `skills/screenshot/` | `/screenshot` | Capture the left monitor and interpret it with a vision-capable model. |

### Slop-policy skills (default-closed contribution policy)

These implement the admin-side triage toolset described in [klangk#1042](https://github.com/mcdonc/klangk/issues/1042) §5 — a funnel for reviewing items reopened under a default-closed policy. Two stages: a live **action queue** (`triage-reopened`) for items a human already pushed back on, and a time-based **safety net** (`slop-report`) that catches false negatives nobody challenged.

| Directory | Command | What it does |
|---|---|---|
| `skills/review-slop/` | `/review-slop <#>` | Deep-review one item: pulls description, comments, PR diff, author trust, and grounds cited file paths against the real repo tree; computes a 0–100 slop score and recommends reopen / keep-closed / needs-more-info. |
| `skills/triage-reopened/` | `/triage-reopened` | List the triage queue — open items labeled `valid-reopened` — with author, allowlist status, body excerpt, and recent comments. |
| `skills/reopen/` | `/reopen <#>` | Promote a triage item: drop `valid-reopened`, ensure open, optionally assign / relabel / trust the author (opens an allowlist PR). |
| `skills/keep-closed/` | `/keep-closed <#>` | Dismiss a triage item: re-close, drop `valid-reopened`, post an ack explaining how to get it reopened. |
| `skills/slop-report/` | `/slop-report` | Delta report over a time window, each item scored 0–100, sorted false-negatives-first (legit items still closed). Defaults to since-last-run (persisted cursor); explicit periods (`since yesterday`, `last week`, a date range) do **not** advance the cursor. |

### Shared library

| Directory | What it is |
|---|---|
| `skills/slop-common/` | **Not a skill** — no `SKILL.md`, never loaded by the agent. Shared bash helpers sourced by the five slop-policy skills: the scoring engine (`score.sh`), repo/grounding resolution (`repo.sh`), label + allowlist constants (`labels.sh`), author-trust collection (`collect.sh`), cited-path extraction (`paths.sh`). |

## Extensions catalog

| Directory | What it is |
|---|---|
| `extensions/keybase/` | Keybase chat integration: `keybase_*` tools (status, list, read, send) plus remote control — drive pi from your phone via your self-DM (`pi <prompt>`, `pi stop`, session/directory switching, streaming replies with live tool summaries). See its README for setup. |

## The slop score (0–100, higher = more likely legitimate)

Computed by `slop-common/score.sh`, four components:

| Component | Max | Signals |
|---|---|---|
| Trust | 30 | Allowlist membership, else account age + prior contributions in-repo. |
| Substance | 30 | Body length tiers, presence of a code block, repro-step keywords. |
| Grounding | 25 | Cited file paths checked against `git ls-tree` of the repo; hallucinated paths deduct. |
| Templateness | 15 | Penalty for boilerplate / drive-by phrasing (blocklist). |

Weights are isolated in `score.sh` and tunable via keep-closed-vs-promoted outcomes over time.

## Conventions

Each skill is a self-contained directory: a `SKILL.md` (YAML frontmatter `name` + `description`, then instructions) plus a `scripts/` of orchestration scripts. Scripts do the `gh`/git/jq work and print machine-readable lines or JSON; the model writes all narrative content. Skills are **stateless** — GitHub is the source of truth, the only local state is `slop-report`'s cursor (`~/.local/state/pi-slop/`, outside this repo).

Default repo is resolved from `cwd`; `--repo owner/name` overrides it on every script.
