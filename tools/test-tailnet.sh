#!/bin/bash
# Checks tailnet_ssh from install.sh — the guard that keeps a Tailscale update
# from cutting the SSH session it runs in. Taken out of install.sh itself, with
# `ss` replaced by canned lines, so the test runs the code that ships.
#   bash tools/test-tailnet.sh        (exit 1 on the first wrong answer)
set -u
cd "$(dirname "$0")/.." || exit 1

src="$(sed -n '/^tailnet_ssh()/,/^}/p' install.sh)"
[ -n "$src" ] || { echo "tailnet_ssh not found in install.sh" >&2; exit 1; }
eval "$src"

SS_OUT=""
# shellcheck disable=SC2317  # called from the eval'd tailnet_ssh
ss() { printf '%s\n' "$SS_OUT"; }

fail=0 n=0
# expect LOCAL WANT — WANT is tailnet or lan; LOCAL is the session's local address
expect() {
	local got=lan
	SS_OUT="0      0      $1 192.0.2.10:52910"
	tailnet_ssh && got=tailnet
	n=$((n + 1))
	if [ "$got" != "$2" ]; then
		echo "FAIL: tailnet_ssh for local $1 — want $2, got $got" >&2
		fail=1
	fi
}

expect 198.51.100.7:22 lan         # RFC 5737, stands for any LAN address
expect 203.0.113.9:22 lan
expect 100.64.0.1:22 tailnet         # lower edge of 100.64.0.0/10
expect 100.101.102.103:22 tailnet
expect 100.100.100.100:22 tailnet
expect 100.127.255.254:22 tailnet    # upper edge
expect 100.63.255.255:22 lan         # just below
expect 100.128.0.1:22 lan            # just above
expect 1.100.64.1:22 lan             # 100.64 inside, not at the start
expect '[fd7a:115c:a1e0::1]:22' tailnet
expect '[fd00::1]:22' lan
SS_OUT=""; n=$((n + 1)); tailnet_ssh && { echo "FAIL: no session reads as tailnet" >&2; fail=1; }

[ $fail = 0 ] && echo "tailnet_ssh: $n cases ok"
exit $fail
