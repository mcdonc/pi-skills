#!/usr/bin/env bash
# Keep only the newest N 3D-dependency-graph gists.
#
# Matches gists by their description suffix — "dependency graph (3D)",
# the marker the workon step-10 flow sets — so every other gist on the
# account stays untouched. Newest means highest createdAt. Prints one
# line per deleted gist.

set -euo pipefail

keep=50
marker="dependency graph (3D)"

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)
      keep="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--keep N]" >&2
      exit 2
      ;;
  esac
done

jqprog='[.[][] | {id, description, created_at}]'
jqprog="${jqprog} | map(select((.description // \"\") | endswith(\"$marker\")))"
jqprog="${jqprog} | sort_by(.created_at) | reverse | .[${keep}:] | .[].id"
# gh api forbids --slurp with --jq on this gh version; --paginate
# prints one JSON array per page and jq -s flattens the pages.
ids=$(gh api 'gists?per_page=100' --paginate | jq -sr "$jqprog")

if [ -z "$ids" ]; then
  echo "purge_dep_gists: at or under the ${keep}-gist budget, nothing to do"
  exit 0
fi

count=0
for id in $ids; do
  gh gist delete "$id" --yes
  echo "purge_dep_gists: deleted ${id}"
  count=$((count + 1))
done
echo "purge_dep_gists: deleted ${count} gist(s); kept the newest ${keep}"
