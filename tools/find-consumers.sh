#!/bin/sh
# Lists the public GitHub repositories that use lintux-modkit and the version each pins.
#   sh tools/find-consumers.sh
# One line per repository: <owner/repo> <tag> <commit> <state>
#   state: current (pins the newest tag's commit) | behind:<newest> | unknown-commit | no-ref (uses it, no lintux-modkit.ref)
# Before a release with a Breaking line in CHANGELOG.md, tell the owners of the "behind" lines.
#
# Three searches, because none finds everything: GitHub's code search indexes new repositories
# late (2026-11-15: IceDash, four days old, was missing from both code searches, but found by
# the README search); the README search misses repositories that do not name lintux-modkit there.
# Needs: gh (signed in), git, base64.
set -eu
cd "$(dirname "$0")/.."
SELF="chicohaager/lintux-modkit"
NEWEST=$(git tag --list 'v*' --sort=-v:refname | sed -n 1p)
[ -n "$NEWEST" ] || { echo "find-consumers: no v* tag in this checkout" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
gh api -X GET search/repositories -f q='lintux-modkit in:readme' -f per_page=100 -q '.items[].full_name' >"$T/a"
gh api -X GET search/code -f q='filename:lintux-modkit.ref' -f per_page=100 -q '.items[].repository.full_name' >"$T/b"
gh api -X GET search/code -f q='"chicohaager/lintux-modkit" filename:go.mod' -f per_page=100 -q '.items[].repository.full_name' >"$T/c"
sort -u "$T/a" "$T/b" "$T/c" | while read -r repo; do
  [ -n "$repo" ] && [ "$repo" != "$SELF" ] || continue
  if ! gh api "repos/$repo/contents/lintux-modkit.ref" -q .content >"$T/b64" 2>"$T/err"; then
    if grep -q 'HTTP 404' "$T/err"; then
      echo "$repo - - no-ref"
      continue
    fi
    echo "find-consumers: $repo: $(cat "$T/err")" >&2
    exit 1
  fi
  ref=$(base64 -d "$T/b64")
  tag=$(printf '%s\n' "$ref" | awk 'NR==1{print $1}')
  commit=$(printf '%s\n' "$ref" | awk 'NR==1{print $2}')
  if [ -z "$commit" ] || ! git cat-file -e "$commit^{commit}" 2>/dev/null; then
    state=unknown-commit
  elif [ "$(git rev-parse "$commit^{commit}")" = "$(git rev-parse "$NEWEST^{commit}")" ]; then
    state=current
  else
    state="behind:$NEWEST"
  fi
  echo "$repo ${tag:--} ${commit:--} $state"
done
