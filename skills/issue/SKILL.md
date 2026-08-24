---
name: issue
description: Open a GitHub issue from a natural-language description. Summarizes the description into a structured title + body, files it in the repo of the current context (or a repo mentioned in the description). Use when the user says /issue <description> or asks to create/file/open a GitHub issue.
---

# Issue skill

Turn a natural-language description of a problem into a well-structured GitHub
issue and file it — in the repo of the current working directory, or in a
different repo the user names in their description.

## Command

- `issue.sh --title <TITLE> --body <BODY|-> [--repo <OWNER/NAME>] [--label <L>...]`
  ` [--assignee <A>...] [--milestone <M>] [--project <P>...]`

Arguments:
- `--title`   — required. The issue title (you write this from the description).
- `--body`    — required. The issue body, or `-` to read it from stdin.
- `--repo`    — optional. `owner/name` of the target repo. Defaults to the repo
                of the current working directory (detected via `gh`).
- `--label`   — repeatable. Adds labels (silently skipped if a label doesn't
                exist on the repo).
- `--assignee`— repeatable. `@me` resolves to the current user.
- `--milestone`, `--project` — optional metadata.

The script does **not** summarize text. **You** (the model) read the user's
description and produce the title + body; the script just resolves the target
repo and runs `gh issue create`.

## Invocation

This skill registers as `/skill:issue`. Example user requests:

- `/skill:issue the login page crashes when I click submit twice`
- `/skill:issue in mcdonc/klangk: dark mode toggle doesn't persist across reloads`
- `file an issue: the API returns 500 on /workspaces when the DB is empty`
- `open a github issue about the footer overlapping the sidebar on mobile`

## Workflow

When the user runs `/skill:issue <description>` (or asks equivalently):

### 1. Parse the description

From the user's `<description>`:

- **Extract the target repo** if one is named, e.g. "`mcdonc/klangk`",
  "`in the klangk repo`", "`github.com/mcdonc/klangk`". Map a bare name like
  `klangk` to `owner/name` using the current context's owner if possible;
  otherwise ask. If **no** repo is mentioned, omit `--repo` — the script will
  use the repo of the current working directory.
- **Capture any explicit labels/assignees** the user mentions ("`labeled bug`",
  "`assign to alice`"). Otherwise leave them off; do not invent labels.
- The remainder is the issue content.

### 2. Summarize into a title + body

Write a concise **title** (imperative or factual, ≤80 chars) and a structured
**body** in GitHub-flavored Markdown. A good default body shape:

```markdown
## Summary

<1–3 sentence summary of the problem, in your own words.>

## Steps to reproduce

1. <step>
2. <step>

## Expected
<what should happen>

## Actual
<what happens instead>

## Context
<any logs, versions, URLs, or clues the user provided — quote them verbatim>
```

Adapt the sections to the description: a bug report fits the shape above; a
feature request may use `## Proposal` / `## Motivation` / `## Acceptance
criteria` instead. Keep the user's verbatim evidence (error messages, log lines,
URLs) in a `## Context` block — do not paraphrase logs.

If the description is too vague to form a useful issue (no repro, no symptom,
and you can't reasonably infer them), **ask the user** for the missing piece
before filing. Do not fabricate repro steps.

### 3. File it

Pass your title and body to the script. Prefer stdin for the body so newlines
and quotes are handled cleanly:

```bash
<skill_dir>/scripts/issue.sh \
  --title "<title>" \
  --body - \
  --repo "<owner/name>"   # omit if using the cwd's repo
  [--label "<label>"] ... <<'EOF'
<body in markdown>
EOF
```

The skill directory is the one containing this `SKILL.md`, e.g.
`~/.pi/agent/skills/issue`.

If you extracted labels/assignees, pass them along. If a label doesn't exist
on the repo the script will skip it and still create the issue.

### 4. Report back

Print the returned issue URL to the user. If the script fell back to creating
without labels (because a label didn't apply), mention that.

## Repo resolution rules

- **Repo named in the description** → use it as `--repo owner/name`.
- **No repo named** → omit `--repo`; the script derives it from the current
  directory's git remote via `gh repo view`. If the cwd is not a git repo and
  no `--repo` was given, the script errors — in that case, ask the user which
  repo to file in.
- **Ambiguous** (e.g. bare `klangk` with no owner) → ask the user to confirm
  the full `owner/name` rather than guessing.

## Notes

- The script never edits `.gitignore` or any tracked file — it only shells out
  to `gh issue create`.
- `gh` must be authenticated. The script surfaces gh's error verbatim if auth
  or the repo is unreachable.
- Don't file issues that duplicate existing ones if the user's description
  obviously matches one you can find via `gh issue list` — mention the
  candidate and ask before creating a duplicate.
