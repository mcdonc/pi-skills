---
name: address
description: Address GitHub PR review comments. Given a PR number or URL, detects comments needing a response (statelessly — unresolved inline threads, plus the latest top-level comment when its author isn't you), makes code changes to address them in a worktree, pushes, posts replies on the PR, resolves the threads, and summarizes. Re-runnable to pick up newly-added comments. Use when the user says /address <PR# or URL> or asks to address/respond to PR comments.
---

# Address skill

Address outstanding review comments on a GitHub pull request: detect which
comments still need a response, implement the requested changes in a worktree,
push them to the PR branch, reply to each comment on GitHub, and summarize.

Re-running the skill only re-surfaces **new** comments — see
[New-comment detection](#new-comment-detection) below.

## Command

- `address.sh <subcommand> ...`

Subcommands (the script does the gh/git work; **you** write code and replies):

- `setup <PR> [REPO] [--dir <DIR>]` — ensure a worktree exists for the PR's head
  branch, off `pull/<PR>/head`. Prints `WORKTREE_PATH=`, `BRANCH=`, `PR_URL=`.
  Reuses an existing worktree for that PR.
- `fetch <PR> [REPO] [--comment <ID|URL>]` — fetch all review threads + the
  latest top-level PR comment, classify which need attention, print JSON. This
  is the source of truth for what to address. Inline review threads need
  attention iff **unresolved** (resolution is the dedup signal — see
  [Shared login](#shared-login) below). `--comment` overrides detection and
  surfaces one specific comment (by `discussion_r<ID>`, `issuecomment-<ID>`,
  `#r<ID>` URL, or bare id) regardless of author/state — use it for top-level
  comments, which have no resolution, or to point the agent at a specific
  thread.
- `reply <PR> <COMMENT_ID> [REPO] --body <BODY|->` — post a reply to an inline
  review comment (in the same thread). `<COMMENT_ID>` is the `last_comment_id`
  from `fetch`. Pair with `resolve` so the thread drops off future runs.
- `comment <PR> [REPO] --body <BODY|->` — post a top-level PR comment (for
  responding to a review summary or an issue-style comment with no inline
  thread).
- `resolve <THREAD_NODE_ID> [REPO]` — best-effort resolve a review thread (uses
  the thread's GraphQL `id` from `fetch`).

`<PR>` may be a number (e.g. `925`) or a full URL
(`https://github.com/mcdonc/klangk/pull/925`). `REPO` is `owner/name` and
defaults to the current directory's repo.

The skill directory is the one containing this `SKILL.md`, e.g.
`~/.pi/agent/skills/address`.

## Invocation

This skill registers as `/skill:address`. Example user requests:

- `/skill:address 925`
- `/skill:address https://github.com/mcdonc/klangk/pull/925`
- `address the review comments on PR 925`
- `respond to the new comments on #925` (re-run; only new ones surface)

## Workflow

When the user runs `/skill:address <PR>` (or asks equivalently):

### 1. Set up a worktree on the PR branch

```bash
<skill_dir>/scripts/address.sh setup <PR>
```

Capture `WORKTREE_PATH`, `BRANCH`, and `PR_URL` from the output. **Run all
editing/build/test/git commands inside `WORKTREE_PATH`** (use `cd` for shell
commands, or absolute paths under `WORKTREE_PATH` for read/edit). The local
branch is `pr-<N>`; push back to the PR's real head branch (see step 5).

### 2. Fetch comments needing attention

```bash
<skill_dir>/scripts/address.sh fetch <PR>
```

Read the JSON. Key fields:

- `agent_login` — the gh-authed login. (No longer the dedup signal for inline
  threads — see [Shared login](#shared-login) below.)
- `targeted` — true when `--comment` was used (focused mode surfaces only that
  one comment).
- `threads_needing_attention` — inline review threads that need a response
  (unresolved ones; or the one targeted by `--comment`). Each has `thread_id`,
  `last_comment_id`, `last_comment_author`, `last_comment_body`, the
  `path`/`line` it's attached to, an `outdated` flag, a `resolved` flag, and
  the full `comments` history of the thread.
- `issue_comment_needing_attention` — the latest top-level PR comment if it's
  not by `agent_login` (may be empty). Top-level comments have no resolution,
  so when you and the commenter share a login this is always empty — use
  `--comment <URL>` to target one.
- `summary` — counts.

If `summary.needs_attention_threads == 0` and `issue_comment_needing_attention`
is empty: tell the user there are no outstanding comments and post `PR_URL`.
Stop.

### 3. Address each thread

For every thread in `threads_needing_attention`, in turn:

1. **Understand the request.** Read `last_comment_body` and the thread's earlier
   `comments` for context. Note `path` and `line`. If `outdated` is true the line
   no longer maps to the current diff — find the corresponding code by searching
   the surrounding text rather than relying on the line number.
2. **Make the change.** Open the file in `WORKTREE_PATH` at the relevant location
   and implement the fix the reviewer asked for. Run lint/tests if the repo has
   them.
3. **Commit.** Make a focused commit on the `pr-<N>` branch with a clear message
   referencing the thread (e.g. `address review: <short description>`).

If a comment is a question rather than a code-change request, skip the edit and
go straight to step 4 with an answer. If a comment is unclear or needs a
decision from the reviewer, say so in the reply and ask — don't guess at large
changes.

### 4. Reply on the PR

Push first (step 5), then post a reply so the thread's last comment becomes
yours (this is what marks it addressed):

```bash
<skill_dir>/scripts/address.sh reply <PR> <last_comment_id> --body - <<'EOF'
Done in <commit-short-sha>: <one-line summary of the change>.

<2–4 sentences: what the comment asked for, what you changed, why. If you
pushed, mention the commit. If you only answered a question, answer it here.>
EOF
```

- Reference the commit SHA you pushed so the reviewer can find the diff.
- Be specific and honest. If you pushed back on a request (with reasoning),
  say so plainly.
- One reply per thread. Replying is what marks the thread addressed — **always
  reply**, even if the change was trivial.

For a top-level `issue_comment_needing_attention`, respond with:

```bash
<skill_dir>/scripts/address.sh comment <PR> --body - <<'EOF'
<body>
EOF
```

### 5. Push to the PR branch

The worktree's local branch `pr-<N>` tracks the read-only `pull/<N>/head` ref,
so push to the PR's **real head branch**. `fetch` gives you `head_branch` under
`pr.head_branch`.

- Same-repo PR (you have push access to the head branch):
  ```bash
  cd <WORKTREE_PATH>
  git push origin HEAD:<head_branch>
  ```
- Fork PR: add the fork as a remote and push there (only works if you have push
  access to the contributor's fork). If you can't push, **do not post replies
  claiming fixes** — tell the user the push failed and ask how to proceed.

If push fails due to branch protection or no access, stop, report the error, and
ask the user before continuing.

### 6. Resolve the thread (default)

Resolving is what marks an inline thread addressed for the next run (it drops
off `fetch`), so do it after every reply:

```bash
<skill_dir>/scripts/address.sh resolve <thread_id>
```

`thread_id` is the GraphQL node id from `fetch`. This is best-effort; if it
fails, the reply is still posted — the thread will resurface next run and you
can re-resolve. (If the last comment in a resurfaced thread is already your
reply and nothing new was asked, just re-run `resolve`.) A human follow-up
reply reopens the thread on GitHub, so it correctly resurfaces.

### 7. Summarize in chat

After addressing all threads, post a summary to the user:

- The PR link (`PR_URL`).
- For each addressed thread: a one-line description of the comment and what you
  did, plus the reply's GitHub URL (printed by `reply`).
- Anything you couldn't address or pushed back on, with the reason.
- The commit SHA(s) pushed.

## New-comment detection

The skill is **stateless** — it keeps no local record of what's been addressed.
`fetch` classifies:

- an **inline review thread** as needing attention iff it is **not resolved**
  (regardless of who left the last comment);
- the **latest top-level PR comment** as needing attention iff its author is not
  `agent_login`.

Consequences:

- After you `reply` to a thread, `resolve` it → it drops off the next `fetch`.
  No duplicate work.
- If a reviewer adds a new comment in a resolved thread, GitHub reopens it → it
  reappears on the next run. Re-running `/skill:address <PR>` picks up exactly
  those reopened threads.
- Resolved threads never reappear.

## Shared login

When the agent and the human PR author use the **same GitHub login** (the common
 case for a solo maintainer running this skill), every comment — the human's
 questions and the agent's replies alike — is authored by `agent_login`. The
 "last comment author == agent" heuristic therefore **cannot** tell a question
 from a reply, so inline threads dedup by **resolution** instead: unresolved →
 needs attention; reply + resolve → done. This makes `/address <PR>` surface the
 human's own questions automatically.

Top-level PR comments have no resolution state, so for those the author
 heuristic is all there is — and it never fires under a shared login. Use
 `fetch <PR> --comment <URL>` (or a bare id) to point the agent at a specific
 top-level comment explicitly. `--comment` also works for inline threads as an
 override.

So "address may be called multiple times" just works: run the skill again
whenever new comments arrive; `fetch` returns unresolved threads (and the
latest non-self top-level comment) — only what still needs you.

## Notes

- Worktrees live at `<repo_root>/.worktrees/pr-<N>` and are excluded from git
  status via `.git/info/exclude` (no changes to `.gitignore`).
- The script never edits tracked files or writes reply text — it only fetches
  state and performs gh calls. All code edits and reply wording are yours.
- `gh` must be authenticated. The script surfaces gh errors verbatim.
- For fork PRs, pushing back requires write access to the fork's head branch; if
  unavailable, the skill can still prepare commits locally for the user to push
  manually — report that clearly instead of failing silently.
