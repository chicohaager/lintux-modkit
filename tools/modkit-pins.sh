#!/bin/bash
# The modules that build Go against ../lintux-modkit carry two copies from here and one pin:
#   scripts/modkit-check.sh      = sysext/modkit-check.sh       (build.sh refuses another lintux-modkit than the pin)
#   tools/test-modkit-check.sh   = sysext/test-modkit-check.sh
#   lintux-modkit.ref            = "<tag> <commit>"
# check compares the copies byte for byte and resolves each pin in this repository; set writes a pin.
#   bash tools/modkit-pins.sh check [<module dir>…]     default: every ../*/ with a lintux-modkit.ref
#   bash tools/modkit-pins.sh set <tag> <module dir>…   only the named directories: the checkouts next to this one
#                                                       sit on different branches
# rc: 0 all good · 1 a copy differs or is missing, or a pin does not resolve to its commit · 2 usage or set refused
set -euo pipefail
cd "$(dirname "$0")/.."
MK=$PWD

usage() { sed -n '7,9p' "$0" >&2; exit 2; }
same() { # same <module file> <file here>: ok, differs or missing
  if [ ! -f "$1" ]; then echo missing; elif cmp -s "$1" "$MK/$2"; then echo ok; else echo differs; fi
}

check() {
  local dirs=("$@") bad=0 d tag commit at c t r
  if [ ${#dirs[@]} = 0 ]; then
    for f in "$MK"/../*/lintux-modkit.ref; do [ -f "$f" ] && dirs+=("$(dirname "$f")"); done
  fi
  [ ${#dirs[@]} -gt 0 ] || { echo "no module with lintux-modkit.ref next to $MK" >&2; return 1; }
  for d in "${dirs[@]}"; do
    c=$(same "$d/scripts/modkit-check.sh" sysext/modkit-check.sh)
    t=$(same "$d/tools/test-modkit-check.sh" sysext/test-modkit-check.sh)
    r=ok
    if ! read -r tag commit < "$d/lintux-modkit.ref" 2>/dev/null || [ -z "${commit:-}" ]; then
      r="unreadable"; tag="?"; commit="?"
    elif ! git -C "$MK" cat-file -e "$commit^{commit}" 2>/dev/null; then
      r="commit not in $MK"
    elif ! at=$(git -C "$MK" rev-parse -q --verify "$tag^{commit}"); then
      r="$tag unknown here"
    elif [ "$at" != "$commit" ]; then
      r="$tag is ${at:0:7} here"
    fi
    [ "$c$t$r" = okokok ] || bad=1
    printf '%-40s %-28s check=%s test=%s pin=%s %s %s\n' "$(cd "$d" && pwd -P | sed "s|^$HOME/|~/|")" \
      "[$(git -C "$d" branch --show-current 2>/dev/null || echo -)]" "$c" "$t" "$tag" "${commit:0:7}" "$r"
  done
  return $bad
}

set_pin() {
  [ $# -ge 2 ] || usage
  local tag=$1 commit d old
  shift
  commit=$(git -C "$MK" rev-parse -q --verify "$tag^{commit}") || { echo "refused: $tag is no commit in $MK" >&2; exit 2; }
  for d in "$@"; do
    [ -f "$d/scripts/modkit-check.sh" ] || { echo "refused: $d has no scripts/modkit-check.sh (not a module with the pin)" >&2; exit 2; }
  done
  git -C "$MK" rev-parse -q --verify "refs/tags/$tag" > /dev/null || echo "WARNING: $tag is not a tag – a release pins a tag" >&2
  for d in "$@"; do
    old=$(cat "$d/lintux-modkit.ref" 2>/dev/null || echo "(none)")
    echo "$tag $commit" > "$d/lintux-modkit.ref"
    echo "$d: $old -> $tag $commit"
  done
}

case "${1:-}" in
  check) shift; check "$@" ;;
  set) shift; set_pin "$@" ;;
  *) usage ;;
esac
