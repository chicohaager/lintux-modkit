#!/bin/bash
# Runs the decision part of install.sh (everything from "--- main" on) with
# the network and the host stubbed, and checks which modules get installed.
# The case that matters: an installed Tailscale or mergerfs changes only when
# the run names it (--install NAME or --only NAME), never on a plain run.
#   bash tools/test-decisions.sh        (exit 1 on the first wrong answer)
# The stubs and settings below are read by the eval'd install.sh code.
# shellcheck disable=SC2034,SC2317,SC2329
set -u
cd "$(dirname "$0")/.." || exit 1

main="$(sed -n '/^# --- main/,$p' install.sh)"
semver="$(sed -n '/^semver_lt()/,/^}/p' install.sh)"
if [ -z "$main" ] || [ -z "$semver" ]; then
	echo "main or semver_lt not found in install.sh" >&2; exit 1
fi

# run STACK HAVE_TAILSCALE ARGS… — prints the INSTALL lines of one run
run() {
	local stack="$1" have_ts="$2"; shift 2
	(
		STACK="$stack" ONLY="$stack" ADD="$stack" CHECK=0 FORCE=0 NEXT=""
		for a in "$@"; do
			case "$a" in
				--force) FORCE=1 ;;
				--only=*) ONLY="${a#--only=}" ;;
				--install=*) ADD="${a#--install=}" ;;
			esac
		done
		ARCH=amd64 WORK=/nonexistent VERSION_ID=test
		eval "$semver"
		say() { :; }; warn() { :; }
		latest_tag() { echo v2.0.0; }
		installed_version() { [ "$1" = tailscale ] && { echo "$have_ts"; return; }; echo "${HAVE_OTHER:-2.0.0}"; }
		is_present() { true; }
		version_by_file() { case "$1" in mergerfs|tailscale) true ;; *) false ;; esac; }
		json_field() { echo 0; }
		pgrep() { return 1; }
		tailnet_ssh() { false; }
		ts_installed() { [ -n "${TS_HAVE-1.0.0}" ] && echo "${TS_HAVE-1.0.0}"; }
		ts_target()    { [ -n "${TS_WANT-1.0.0}" ] && echo "${TS_WANT-1.0.0}"; }
		install_tailscale() { echo "INSTALL tailscale with ${2-}"; }
		install_mergerfs()  { echo "INSTALL mergerfs"; }
		install_zfw()       { echo "INSTALL zfw"; }
		install_raw()       { echo "INSTALL $1"; }
		eval "$main"
	)
}

fail=0 n=0
# expect WANT STACK HAVE_TAILSCALE ARGS… — WANT: tailscale installed or not
expect() {
	local want="$1" got=no out; shift
	out="$(run "$@")"
	case "$out" in *"INSTALL tailscale"*) got=yes ;; esac
	n=$((n + 1))
	if [ "$got" != "$want" ]; then
		echo "FAIL: stack='$1' tailscale=$2 args='${*:3}' — want install=$want, got $got" >&2
		fail=1
	fi
}

# installed 1.0.0, release 2.0.0
expect no  ""                 1.0.0                       # plain install.sh run
expect no  ""                 1.0.0 --force               # --force alone does not name it
expect yes ""                 1.0.0 --install=tailscale
expect yes ""                 1.0.0 --only=tailscale
expect yes ""                 1.0.0 --only=cron,tailscale
expect no  ""                 1.0.0 --only=cron
expect no  "zfw,cron,zbackup" 1.0.0                       # ready-made installers
expect no  "cron,zbackup"     1.0.0
expect yes "cron,zbackup"     1.0.0 --only=tailscale
# version unknown (own build, or before 1.0.4)
expect no  ""                 ""
expect no  ""                 "" --force
expect yes ""                 "" --install=tailscale
# up to date
expect no  ""                 2.0.0 --install=tailscale
expect yes ""                 2.0.0 --install=tailscale --force
# the other modules still update on a plain run, and only when old
out="$(HAVE_OTHER=1.0.0 run "" 2.0.0)"; n=$((n + 1))
case "$out" in *"INSTALL zfw"*) ;; *) echo "FAIL: plain run left an old zfw alone" >&2; fail=1 ;; esac
out="$(run "" 2.0.0)"; n=$((n + 1))
[ -z "$out" ] || { echo "FAIL: up-to-date plain run installed: $out" >&2; fail=1; }

# Tailscale itself behind upstream, module current (2.0.0 = release)
expect_ts() { # WANT TS_HAVE TS_WANT ARGS…
	local want="$1" th="$2" tw="$3" got=no out; shift 3
	out="$(TS_HAVE="$th" TS_WANT="$tw" run "" 2.0.0 "$@")"
	case "$out" in *"INSTALL tailscale with $tw"*) got=yes ;; *"INSTALL tailscale"*) got="yes-but:$out" ;; esac
	n=$((n + 1))
	if [ "$got" != "$want" ]; then
		echo "FAIL: Tailscale $th → $tw args='$*' — want install=$want, got $got" >&2
		fail=1
	fi
}
expect_ts no  1.104.1 1.106.0                       # plain run: reported, not applied
expect_ts no  1.104.1 1.106.0 --force
expect_ts yes 1.104.1 1.106.0 --install=tailscale   # built with the newer Tailscale
expect_ts yes 1.104.1 1.106.0 --only=tailscale
expect_ts no  1.106.0 1.106.0 --install=tailscale   # current
expect_ts no  1.106.0 1.104.1 --install=tailscale   # upstream older: no downgrade
expect_ts no  1.104.1 ""      --install=tailscale   # upstream unknown: module decides
expect_ts no  ""      1.106.0 --install=tailscale   # Tailscale version unreadable, module current
# a pin (TAILSCALE_VERSION) wins in both directions
out="$(TAILSCALE_VERSION=1.102.0 TS_HAVE=1.104.1 TS_WANT=1.102.0 run "" 2.0.0 --install=tailscale)"; n=$((n + 1))
case "$out" in *"INSTALL tailscale with 1.102.0"*) ;; *) echo "FAIL: pin 1.102.0 not installed: $out" >&2; fail=1 ;; esac

[ $fail = 0 ] && echo "decisions: $n cases ok"
exit $fail
