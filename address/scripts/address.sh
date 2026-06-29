#!/usr/bin/env bash
# address.sh — help address GitHub PR review comments.
#
# Subcommands:
#   setup   <PR> [REPO] [--dir <DIR>]
#           Ensure a worktree exists for the PR's head branch and print
#           WORKTREE_PATH=/BRANCH=/PR_URL=. Reuses an existing worktree.
#   fetch   <PR> [REPO]
#           Fetch all review threads + top-level PR comments, classify which
#           need attention, and print JSON. A thread needs attention iff it is
#           not resolved AND its last comment author != the current gh user.
#           (Stateless: after you reply to a thread it drops off; when a
#           reviewer replies again it reappears.)
#   reply   <PR> <COMMENT_ID> [REPO] --body <BODY|->
#           Post a reply to an inline review comment (its thread's last comment
#           becomes yours, marking it addressed).
#   comment <PR> [REPO] --body <BODY|->
#           Post a top-level PR comment (for responding to review summaries or
#           issue-style comments that have no inline thread).
#   resolve <THREAD_NODE_ID> [REPO]
#           Best-effort resolve a review thread via GraphQL.
#
# <PR> may be a number (e.g. 911) or a full PR URL
# (e.g. https://github.com/mcdonc/klangk/pull/911). REPO is owner/name and
# defaults to the current directory's repo.
#
# This script does NOT make code changes or write replies' text — the caller
# (the agent) edits files and composes reply bodies. The script only fetches
# state and performs the gh calls.
set -uo pipefail

# ---------------------------------------------------------------------------
# helpers

# parse_pr <arg> -> echoes "OWNER REPO NUMBER" (owner/repo from arg or cwd).
# Sets globals PARSED_OWNER PARSED_REPO PARSED_NUM.
parse_pr() {
  local arg="$1"
  local owner="" repo="" num=""
  if [[ "$arg" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; num="${BASH_REMATCH[3]}"
  elif [[ "$arg" =~ ^[0-9]+$ ]]; then
    num="$arg"
    # owner/repo from cwd
    if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
      echo "address.sh: '$arg' is a number but not in a git repo; pass a full PR URL or run from the repo." >&2
      exit 1
    fi
    local full
    full="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || {
      echo "address.sh: could not resolve repo from cwd (gh auth? remote?)." >&2
      exit 1
    }
    owner="${full%%/*}"; repo="${full#*/}"
  else
    echo "address.sh: '$arg' is not a PR number or URL." >&2
    exit 2
  fi
  PARSED_OWNER="$owner"; PARSED_REPO="$repo"; PARSED_NUM="$num"
}

# resolve optional REPO override passed after the PR arg.
# Usage: after parse_pr, if next args are owner/name, override.
# (Handled inline per subcommand.)

current_login() {
  gh api user --jq .login 2>/dev/null
}

# ---------------------------------------------------------------------------
# setup <PR> [REPO] [--dir <DIR>]
cmd_setup() {
  local pr="$1"; shift
  parse_pr "$pr"
  # optional explicit repo override
  if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    local ov="$1"; shift
    PARSED_OWNER="${ov%%/*}"; PARSED_REPO="${ov#*/}"
  fi
  local custom_dir=""
  if [ $# -ge 2 ] && [ "$1" = "--dir" ]; then custom_dir="$2"; fi

  local owner="$PARSED_OWNER" repo="$PARSED_REPO" num="$PARSED_NUM"
  local GH=(gh --repo "$owner/$repo")

  local prinfo
  prinfo="$("${GH[@]}" pr view "$num" --json number,headRefName,headRepository,headRepositoryOwner,url,state 2>/dev/null)" || {
    echo "address.sh: could not fetch PR #$num in $owner/$repo." >&2
    exit 1
  }
  local head_branch head_repo_owner head_repo url state base_default
  eval "$(printf '%s' "$prinfo" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ho=(d.get("headRepositoryOwner") or {}).get("login","")
hr=(d.get("headRepository") or {}).get("name","")
print("head_branch=%r" % d.get("headRefName",""))
print("head_repo_owner=%r" % ho)
print("head_repo=%r" % hr)
print("url=%r" % d.get("url",""))
print("state=%r" % d.get("state",""))
')"
  [ -z "$head_branch" ] && { echo "address.sh: PR #$num has no head branch (deleted?)." >&2; exit 1; }

  base_default="$("${GH[@]}" repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
  [ -z "$base_default" ] && base_default="main"

  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "address.sh: not inside a git repository." >&2
    exit 1
  }
  local worktree_dir="${custom_dir:-${repo_root}/.worktrees/pr-${num}}"
  local local_branch="pr-${num}"

  # Ensure .worktrees ignored (local-only).
  local exclude="${repo_root}/.git/info/exclude"
  mkdir -p "${repo_root}/.git/info"
  grep -qxF ".worktrees/" "$exclude" 2>/dev/null || printf '\n# pi address skill\n.worktrees/\n' >> "$exclude"

  echo "PR #$num  state=$state  head_branch=$head_branch  (head repo: ${head_repo_owner}/${head_repo})"
  echo "url=$url"

  # Reuse existing worktree for the local branch, if any.
  local existing
  existing="$(git worktree list --porcelain 2>/dev/null | python3 -c '
import sys
path=branch=None
out=""
for line in sys.stdin:
    line=line.rstrip("\n")
    if line.startswith("worktree "): path=line[9:]; branch=""
    elif line.startswith("branch "): branch=line[7:].replace("refs/heads/","")
    elif line.strip()=="" and path:
        out += path+"\t"+branch+"\n"; path=branch=None
if path: out += path+"\t"+branch+"\n"
print(out)
' | awk -v b="$local_branch" -F'\t' '$2==b{print $1; exit}')"
  if [ -n "$existing" ]; then
    echo "Reusing existing worktree: $existing"
    echo "WORKTREE_PATH=$existing"
    echo "BRANCH=$local_branch"
    echo "PR_URL=$url"
    return 0
  fi

  # Fetch the PR head ref (works for same-repo AND fork PRs).
  echo "Fetching PR #$num head..."
  git fetch --quiet origin "pull/${num}/head:${local_branch}" 2>&1 || {
    # fallback: fetch without writing a local branch
    git fetch --quiet origin "pull/${num}/head" 2>&1 || {
      echo "address.sh: git fetch pull/${num}/head failed." >&2
      exit 1
    }
  }

  echo "Creating worktree at $worktree_dir..."
  if git show-ref --verify --quiet "refs/heads/$local_branch" 2>/dev/null; then
    git worktree add --force "$worktree_dir" "$local_branch" 2>&1 || { echo "address.sh: git worktree add failed." >&2; exit 1; }
  else
    git worktree add -b "$local_branch" "$worktree_dir" FETCH_HEAD 2>&1 || { echo "address.sh: git worktree add failed." >&2; exit 1; }
  fi

  echo
  echo "WORKTREE_PATH=$worktree_dir"
  echo "BRANCH=$local_branch"
  echo "PR_URL=$url"
  echo
  echo "Note: pushing changes back requires write access to the PR's head branch."
  echo "  same-repo PR: git push origin HEAD:$head_branch"
  echo "  fork PR:      add the fork as a remote and push there (if you have access)."
}

# ---------------------------------------------------------------------------
# fetch <PR> [REPO]
cmd_fetch() {
  local pr="$1"; shift
  parse_pr "$pr"
  if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    local ov="$1"; shift
    PARSED_OWNER="${ov%%/*}"; PARSED_REPO="${ov#*/}"
  fi
  # --comment <ID|URL>: surface one specific comment for the agent to answer,
  # regardless of author or resolution state (see SKILL.md "Shared login").
  local comment_target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --comment) comment_target="$2"; shift 2;;
      --comment=*) comment_target="${1#--comment=}"; shift;;
      *) shift;;
    esac
  done
  local owner="$PARSED_OWNER" repo="$PARSED_REPO" num="$PARSED_NUM"
  local me; me="$(current_login)"
  [ -z "$me" ] && { echo "address.sh: could not determine current gh user (gh auth?)." >&2; exit 1; }

  local query='query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$pr){
        number title url state headRefName baseRefName
        reviewThreads(first:100){
          nodes{ id isResolved isOutdated path line
            comments(first:100){ nodes{ databaseId author{login} body createdAt path line originalLine } } }
        }
        comments(first:100){ nodes{ databaseId author{login} body createdAt } }
      }
    }
  }'
  gh api graphql -f query="$query" -f owner="$owner" -f name="$repo" -F pr="$num" 2>/tmp/addr_gql.err \
    | python3 -c '
import json,sys,re
err=sys.stderr
try:
    d=json.load(sys.stdin)
except Exception as e:
    err.write("address.sh: failed to parse GraphQL response\n"); sys.exit(1)
if "errors" in d:
    err.write("address.sh: GraphQL errors: "+json.dumps(d["errors"])+"\n"); sys.exit(1)
pr=d["data"]["repository"]["pullRequest"]
me=sys.argv[1]
ct=sys.argv[2] if len(sys.argv)>2 else ""
def last(c): return c[-1] if c else None
def thread_entry(t, reply_to_id=None):
    cs=t["comments"]["nodes"]
    lc=last(cs)
    rid=reply_to_id if reply_to_id is not None else (lc["databaseId"] if lc else None)
    return {
        "thread_id": t["id"],
        "needs_attention": True,
        "outdated": t["isOutdated"],
        "resolved": t["isResolved"],
        "path": t.get("path"),
        "line": t.get("line"),
        "last_comment_id": rid,
        "last_comment_author": lc["author"]["login"] if lc else None,
        "last_comment_body": lc["body"] if lc else None,
        "last_comment_at": lc["createdAt"] if lc else None,
        "comments": [ {"id":c["databaseId"],"author":c["author"]["login"],"body":c["body"],"at":c["createdAt"]} for c in cs ],
    }
threads=pr["reviewThreads"]["nodes"]
ic=pr["comments"]["nodes"]
needs=[]; ic_needs=[]; done=0; targeted=False

# --- explicit --comment targeting (shared-login-safe) ---
target_id=None; target_kind=None  # kind: "review" | "issue" | None(ambiguous)
if ct:
    m=re.search(r"discussion_r(\d+)", ct)
    if m: target_id=int(m.group(1)); target_kind="review"
    elif re.search(r"issuecomment-(\d+)", ct):
        m=re.search(r"issuecomment-(\d+)", ct); target_id=int(m.group(1)); target_kind="issue"
    elif re.search(r"#r(\d+)", ct):
        m=re.search(r"#r(\d+)", ct); target_id=int(m.group(1)); target_kind="review"
    elif ct.isdigit():
        target_id=int(ct); target_kind=None
    else:
        m=re.search(r"(\d+)$", ct)
        if m: target_id=int(m.group(1)); target_kind=None
if target_id is not None:
    targeted=True
    found=False
    if target_kind != "issue":  # search inline review threads
        for t in threads:
            for c in t["comments"]["nodes"]:
                if c["databaseId"]==target_id:
                    needs.append(thread_entry(t, reply_to_id=target_id)); found=True; break
            if found: break
    if not found and target_kind != "review":  # fall back to top-level issue comments
        for c in ic:
            if c["databaseId"]==target_id:
                ic_needs=[{"id":c["databaseId"],"author":c["author"]["login"],"body":c["body"],"at":c["createdAt"]}]
                found=True; break
    if not found:
        err.write("address.sh: comment "+repr(ct)+" not found on PR #"+str(pr["number"])+"\n"); sys.exit(1)
    done=len(threads)-len(needs)
else:
    # --- default detection ---
    # Inline review threads: surface iff UNRESOLVED. Resolution is the dedup
    # signal, because when the agent and the human share a GitHub login,
    # "last comment author == agent" cannot tell the agent reply from
    # the human question. After replying, resolve the thread so it drops
    # off; a human follow-up reopens it (GitHub) so it resurfaces here.
    for t in threads:
        if t["isResolved"]:
            done+=1; continue
        cs=t["comments"]["nodes"]
        lc=last(cs)
        if lc is None:
            done+=1; continue
        needs.append(thread_entry(t))
    # Top-level PR (issue) comments have no resolution state, so the author
    # heuristic is all we have for them. When agent and author share a login
    # it never fires -- use --comment to target one explicitly.
    if ic:
        last_ic=ic[-1]
        if last_ic["author"]["login"] != me:
            ic_needs=[{"id":last_ic["databaseId"],"author":last_ic["author"]["login"],"body":last_ic["body"],"at":last_ic["createdAt"]}]

out={
  "pr": {"number":pr["number"],"title":pr["title"],"url":pr["url"],"state":pr["state"],
         "head_branch":pr["headRefName"],"base_branch":pr["baseRefName"]},
  "agent_login": me,
  "targeted": targeted,
  "threads_needing_attention": needs,
  "issue_comment_needing_attention": ic_needs,
  "threads_already_addressed_or_resolved": done,
  "summary": {
     "needs_attention_threads": len(needs),
     "needs_attention_issue_comment": len(ic_needs),
     "addressed_or_resolved": done,
     "total_threads": len(threads),
  }
}
print(json.dumps(out,indent=2))
' "$me" "$comment_target" || { cat /tmp/addr_gql.err >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# reply <PR> <COMMENT_ID> [REPO] --body <BODY|->
cmd_reply() {
  local pr="$1"; shift
  local comment_id="$1"; shift
  parse_pr "$pr"
  if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    local ov="$1"; shift
    PARSED_OWNER="${ov%%/*}"; PARSED_REPO="${ov#*/}"
  fi
  local owner="$PARSED_OWNER" repo="$PARSED_REPO" num="$PARSED_NUM"
  [ $# -ge 2 ] || { echo "address.sh reply: --body is required" >&2; exit 2; }
  [ "$1" = "--body" ] || { echo "address.sh reply: expected --body, got '$1'" >&2; exit 2; }
  local body_arg="$2"
  if [ "$body_arg" = "-" ]; then
    body_file="$(mktemp)"   # global so the EXIT trap can see it
    trap 'rm -f "${body_file:-}"' EXIT
    cat > "$body_file"
    gh api -X POST "repos/${owner}/${repo}/pulls/${num}/comments/${comment_id}/replies" \
      -F "body=@${body_file}" 2>&1
    rm -f "$body_file"; trap - EXIT
  else
    gh api -X POST "repos/${owner}/${repo}/pulls/${num}/comments/${comment_id}/replies" \
      -f "body=$body_arg" 2>&1
  fi
}

# ---------------------------------------------------------------------------
# comment <PR> [REPO] --body <BODY|->
cmd_comment() {
  local pr="$1"; shift
  parse_pr "$pr"
  if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    local ov="$1"; shift
    PARSED_OWNER="${ov%%/*}"; PARSED_REPO="${ov#*/}"
  fi
  local owner="$PARSED_OWNER" repo="$PARSED_REPO" num="$PARSED_NUM"
  [ $# -ge 2 ] || { echo "address.sh comment: --body is required" >&2; exit 2; }
  [ "$1" = "--body" ] || { echo "address.sh comment: expected --body, got '$1'" >&2; exit 2; }
  local body_arg="$2"
  if [ "$body_arg" = "-" ]; then
    gh pr comment "$num" --repo "$owner/$repo" --body-file - 2>&1
  else
    gh pr comment "$num" --repo "$owner/$repo" --body "$body_arg" 2>&1
  fi
}

# ---------------------------------------------------------------------------
# resolve <THREAD_NODE_ID> [REPO]
cmd_resolve() {
  local thread_id="$1"; shift
  # REPO arg unused for resolve (thread_id is global) but accepted for symmetry.
  [ $# -gt 0 ] && shift
  gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}' \
    -f id="$thread_id" 2>&1 || true
}

# ---------------------------------------------------------------------------
usage() {
  sed -n '2,30p' "$0"; exit 0
}

[ $# -ge 2 ] || usage
SUB="$1"; shift
case "$SUB" in
  setup)  cmd_setup  "$@" ;;
  fetch)  cmd_fetch  "$@" ;;
  reply)  cmd_reply  "$@" ;;
  comment) cmd_comment "$@" ;;
  resolve) cmd_resolve "$@" ;;
  -h|--help) usage ;;
  *) echo "address.sh: unknown subcommand '$SUB'" >&2; exit 2 ;;
esac
