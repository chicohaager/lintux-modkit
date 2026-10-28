#!/bin/bash
# tools/modkit-pins.sh against throwaway checkouts: a lintux-modkit with a tag, modules next to it.
# Also runs sysext/test-modkit-check.sh against sysext/modkit-check.sh in the layout of a module.
#   bash tools/test-modkit-pins.sh
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null
ok=0
fail() { echo "FAIL $1"; exit 1; }
expect() { # expect <rc> <text in output> <case> -- <command>
  local want=$1 text=$2 name=$3 rc=0 out
  shift 4
  out=$("$@" 2>&1) || rc=$?
  { [ "$rc" = "$want" ] && [[ "$out" == *"$text"* ]]; } || fail "$name: rc=$rc (want $want), output: $out"
  ok=$((ok + 1))
}

# the canonical check passes its canonical test, in the layout of a module
mkdir -p "$T/layout/scripts" "$T/layout/tools"
cp sysext/modkit-check.sh "$T/layout/scripts/"
cp sysext/test-modkit-check.sh "$T/layout/tools/"
expect 0 "cases ok" "sysext/test-modkit-check.sh against sysext/modkit-check.sh" -- bash "$T/layout/tools/test-modkit-check.sh"

MK="$T/dev/lintux-modkit"
mkdir -p "$MK/tools" "$MK/sysext"
cp tools/modkit-pins.sh "$MK/tools/"
cp sysext/modkit-check.sh sysext/test-modkit-check.sh "$MK/sysext/"
git -C "$MK" init -q
git -C "$MK" add .
git -C "$MK" -c user.name=t -c user.email=t@example.invalid commit -qm one
git -C "$MK" tag v1.0.0
V1=$(git -C "$MK" rev-parse HEAD)
git -C "$MK" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m two
HEAD2=$(git -C "$MK" rev-parse HEAD)
PINS="$MK/tools/modkit-pins.sh"
module() { # module <name> <pin line>
  mkdir -p "$T/dev/$1/scripts" "$T/dev/$1/tools"
  cp sysext/modkit-check.sh "$T/dev/$1/scripts/"
  cp sysext/test-modkit-check.sh "$T/dev/$1/tools/"
  echo "$2" > "$T/dev/$1/lintux-modkit.ref"
}
module a "v1.0.0 $V1"
module b "v1.0.0 $V1"
mkdir -p "$T/dev/unrelated"

out=$(bash "$PINS" check) || fail "all copies equal, pins resolve: rc=$?, $out"
[ "$(grep -c ' check=ok test=ok pin=v1.0.0 .* ok$' <<< "$out")" = 2 ] || fail "both modules found and ok: $out"
grep -q unrelated <<< "$out" && fail "a directory without lintux-modkit.ref is listed: $out"
ok=$((ok + 1))

echo "# changed" >> "$T/dev/b/scripts/modkit-check.sh"
expect 1 "check=differs" "a changed copy of the check" -- bash "$PINS" check
cp sysext/modkit-check.sh "$T/dev/b/scripts/"
rm "$T/dev/b/tools/test-modkit-check.sh"
expect 1 "test=missing" "a missing copy of the test" -- bash "$PINS" check
cp sysext/test-modkit-check.sh "$T/dev/b/tools/"
echo "v1.0.0 $HEAD2" > "$T/dev/b/lintux-modkit.ref"
expect 1 "v1.0.0 is ${V1:0:7} here" "a pin whose tag names another commit" -- bash "$PINS" check
echo "v1.0.0 0123456789012345678901234567890123456789" > "$T/dev/b/lintux-modkit.ref"
expect 1 "commit not in" "a pin with a commit unknown here" -- bash "$PINS" check
expect 0 "pin=v1.0.0" "check of a named directory only" -- bash "$PINS" check "$T/dev/a"

expect 0 "-> v1.0.0 $V1" "set writes tag and commit" -- bash "$PINS" set v1.0.0 "$T/dev/b"
[ "$(cat "$T/dev/b/lintux-modkit.ref")" = "v1.0.0 $V1" ] || fail "set: file content $(cat "$T/dev/b/lintux-modkit.ref")"
ok=$((ok + 1))
expect 2 "is no commit" "set with an unknown tag" -- bash "$PINS" set v9.9.9 "$T/dev/a"
[ "$(cat "$T/dev/a/lintux-modkit.ref")" = "v1.0.0 $V1" ] || fail "unknown tag changed the pin"
ok=$((ok + 1))
expect 2 "has no scripts/modkit-check.sh" "set on a directory without the check" -- bash "$PINS" set v1.0.0 "$T/dev/unrelated"
[ ! -e "$T/dev/unrelated/lintux-modkit.ref" ] || fail "set wrote into a directory without the check"
ok=$((ok + 1))
git -C "$MK" branch dev
expect 0 "WARNING: dev is not a tag" "set with a branch warns" -- bash "$PINS" set dev "$T/dev/a"
expect 2 "" "no command" -- bash "$PINS"
echo "test-modkit-pins: $ok cases ok"
