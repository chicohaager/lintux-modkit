#!/bin/bash
# Checks semver_lt from install.sh — the function that decides whether an
# installed module is older than the latest release. It is taken out of
# install.sh itself, so the test runs the code that ships, not a copy.
#   bash tools/test-semver.sh        (exit 1 on the first wrong answer)
set -u
cd "$(dirname "$0")/.." || exit 1

src="$(sed -n '/^semver_lt()/,/^}/p' install.sh)"
[ -n "$src" ] || { echo "semver_lt not found in install.sh" >&2; exit 1; }
eval "$src"

fail=0 n=0
# expect A B WANT — WANT is lt (A < B) or ge (A >= B)
expect() {
	local got=ge
	semver_lt "$1" "$2" && got=lt
	n=$((n + 1))
	if [ "$got" != "$3" ]; then
		echo "FAIL: semver_lt $1 $2 — want $3, got $got" >&2
		fail=1
	fi
}

# plain releases
expect 0.2.1 0.3.0 lt
expect 0.3.0 0.2.1 ge
expect 0.3.0 0.3.0 ge
expect 0.9.0 0.10.0 lt
expect 1.0.0 0.99.99 ge
# a pre-release is older than its release (semver §11) — the case that
# left 0.3.0-dev7 installed when 0.3.0 came out
expect 0.3.0-dev7 0.3.0 lt
expect 0.3.0 0.3.0-dev7 ge
expect 0.3.0-rc1 0.3.0 lt
# ... but newer than the release before it
expect 0.3.0-dev7 0.2.1 ge
expect 0.2.1 0.3.0-dev7 lt
# pre-releases of the same version count up naturally (dev10 after dev7)
expect 0.3.0-dev7 0.3.0-dev10 lt
expect 0.3.0-dev10 0.3.0-dev7 ge
expect 0.3.0-dev7 0.3.0-dev7 ge
# build metadata carries no order (semver §10)
expect 0.3.0+abc 0.3.0 ge
expect 0.3.0 0.3.0+abc ge
expect 0.3.0-dev7+abc 0.3.0 lt

[ $fail = 0 ] && echo "semver_lt: $n cases ok"
exit $fail
