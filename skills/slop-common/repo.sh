# shellcheck shell=bash
# slop-common/repo.sh — resolve the target repo as owner/name.
# Sourced by the policy skills. Exposes: slop_resolve_repo

# Echo owner/name for the repo to operate on.
#   $1 = repo arg (may be empty). Empty -> derive from the cwd's git remote.
# Fails (returns non-zero, message to stderr) if it can't be resolved.
slop_resolve_repo() {
  local repo="${1:-}"
  if [ -n "$repo" ]; then
    # Allow a bare URL or an https URL too.
    repo=${repo#https://github.com/}
    repo=${repo#github.com/}
    printf '%s\n' "$repo"
    return 0
  fi
  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || true
  if [ -z "$repo" ]; then
    echo "slop: could not derive repo from cwd and none given (pass --repo OWNER/NAME)" >&2
    return 1
  fi
  printf '%s\n' "$repo"
}

# slop_detect_repo_root <owner/name> -> echoes the absolute path to a local
# checkout of that repo (the cwd, if its origin remote points at it), or empty.
# Used to enable grounding (real-path verification) when a checkout is present;
# empty result means grounding is skipped (neutral) — see score.sh.
slop_detect_repo_root() {
  local target here url lurl
  target=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  here=$(git rev-parse --show-toplevel 2>/dev/null) || { printf '%s\n' ""; return 0; }
  url=$(git -C "$here" remote get-url origin 2>/dev/null) || { printf '%s\n' ""; return 0; }
  lurl=$(printf '%s' "$url" | tr 'A-Z' 'a-z')
  case "$lurl" in
    *github.com[/:]"$target"*) printf '%s\n' "$here" ;;
    *) printf '%s\n' "" ;;
  esac
}
