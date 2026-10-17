#!/bin/bash
# install-without-firewall.sh — generated from install.sh by tools/gen-installers.sh, do not edit.
# Installs or updates these Lintux modules on a ZimaOS host: cron, zbackup.
#   ZFW Firewall (zfw), Cron (cron), Sync & Backup (zbackup),
#   mergerfs + SnapRAID (mergerfs), Tailscale (tailscale).
#
# Run ON the ZimaOS host as root:
#   curl -fsSL https://raw.githubusercontent.com/chicohaager/lintux-modkit/main/install.sh -o /tmp/lintux-install.sh
#   sudo bash /tmp/lintux-install.sh                    # update the modules that are installed
#   sudo bash /tmp/lintux-install.sh --install zbackup  # also install this one (zfw, cron, zbackup, mergerfs, tailscale or all)
#   sudo bash /tmp/lintux-install.sh --check            # only report: installed vs. latest
#   sudo bash /tmp/lintux-install.sh --only cron,zbackup
#   sudo bash /tmp/lintux-install.sh --force            # reinstall even when up to date
#
# Without --install it never adds a module you do not have: not everyone
# wants a firewall, and a firewall nobody asked for can lock people out.
# For every module it reads the installed version (zfw, cron, zbackup: the
# daemon's health route behind the ZimaOS gateway; tailscale: the version in
# its merged extension-release; mergerfs: the image's sha256 against the
# release), asks GitHub for the latest release, downloads the matching asset
# for this CPU, verifies the sha256 the release ships, and installs: zfw
# through its own install.sh (tarball), cron and zbackup through zpkg (a module
# already installed is removed first — jobs, history and keys live under
# /DATA/AppData and are kept), mergerfs and tailscale through their own
# install.sh from the release's source archive (config and login state under
# /DATA/AppData are kept). It never touches a module that is busy (zbackup with
# a running job, a running snapraid) unless --force is given.
set -u

# STACK is empty in install.sh. tools/gen-installers.sh writes the two
# ready-made variants from this file: install-with-firewall.sh (STACK=
# zfw,cron,zbackup) and install-without-firewall.sh (STACK=cron,zbackup).
# With a STACK the script installs those modules when missing and updates
# them when old, and looks at nothing else — no switches needed.
STACK="cron,zbackup"

ONLY="$STACK"; ADD="$STACK"; CHECK=0; FORCE=0; NEXT=""
for a in "$@"; do
	case "$a" in
		--check) CHECK=1 ;;
		--force) FORCE=1 ;;
		--only=*) ONLY="${a#--only=}" ;;
		--install=*) ADD="${a#--install=}" ;;
		--only|--install) NEXT="$a" ;;
		-h|--help) sed -n '2,27p' "$0"; exit 0 ;;
		*) case "$NEXT" in
			--only) ONLY="$a"; NEXT="" ;;
			--install) ADD="$a"; NEXT="" ;;
			*) echo "unknown argument: $a" >&2; exit 2 ;;
		   esac ;;
	esac
done
[ -n "$NEXT" ] && { echo "$NEXT needs a list, e.g. $NEXT cron,zbackup (or all)" >&2; exit 2; }
[ "$ADD" = "all" ] && ADD="zfw,cron,zbackup,mergerfs,tailscale"
for m in ${ADD//,/ } ${ONLY//,/ }; do
	case "$m" in zfw|cron|zbackup|mergerfs|tailscale) ;; *) echo "unknown module: $m (zfw, cron, zbackup, mergerfs, tailscale)" >&2; exit 2 ;; esac
done

say()  { printf '[lintux] %s\n' "$*"; }
warn() { printf '[lintux] WARNING: %s\n' "$*" >&2; }
die()  { printf '[lintux] ERROR: %s\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root:  sudo bash $0"
. /etc/os-release 2>/dev/null || true
[ "${ID:-}" = "zimaos" ] || warn "this is not ZimaOS (ID=${ID:-?}); the modules are built for ZimaOS 1.7"
for t in curl sha256sum tar zpkg systemd-sysext systemctl; do
	command -v "$t" >/dev/null 2>&1 || die "$t not found"
done
case "$(uname -m)" in
	x86_64|amd64)  ARCH=amd64 ;;
	aarch64|arm64) ARCH=arm64 ;;
	*) die "unsupported CPU: $(uname -m)" ;;
esac
WORK="$(mktemp -d /tmp/lintux-install.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
GW="http://127.0.0.1"

# json_field FILE KEY — first string value of KEY in a JSON file (jq if present)
json_field() {
	if command -v jq >/dev/null 2>&1; then
		jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null
	else
		sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p' "$1" | head -n1
	fi
}

# latest_tag REPO — tag of the latest GitHub release (vX.Y.Z), empty on
# failure; curl's own message is kept in $WORK/latest-REPO.err for the warning.
# First the web redirect /releases/latest → /releases/tag/<tag>: it has no API
# quota. The API allows 60 requests an hour per IP — five modules a run, and a
# few runs (or neighbours behind the same address) answer 403 (measured
# 2026-10-17: API at 0 remaining, the redirect still named every tag).
latest_tag() {
	local f="$WORK/latest-$1.json" loc
	loc="$(curl -sS -m 20 -o /dev/null -w '%{redirect_url}' \
		"https://github.com/chicohaager/$1/releases/latest" 2>"$WORK/latest-$1.err")"
	case "$loc" in
		*/releases/tag/?*) echo "${loc##*/releases/tag/}"; return 0 ;;
	esac
	curl -fsSL -m 20 -H 'Accept: application/vnd.github+json' \
		"https://api.github.com/repos/chicohaager/$1/releases/latest" -o "$f" 2>"$WORK/latest-$1.err" || return 1
	json_field "$f" tag_name
}

# raw_name NAME — file name of the module's image in /var/lib/extensions
raw_name() {
	case "$1" in
		mergerfs) echo mergerfs-snapraid ;;
		*)        echo "$1" ;;
	esac
}

# installed_version NAME [TAG] — version the host runs, "" if unknown.
# zfw, cron, zbackup: the daemon's health route (behind the gateway, no login).
# tailscale: SYSEXT_VERSION_ID in its extension-release, present while the
#   image is merged; images built before module 1.0.4 have none.
# mergerfs: neither a daemon nor a version in the image — the installed image
#   counts as TAG when its sha256 equals the one in TAG's SHA256SUMS.
installed_version() {
	local url f sum
	case "$1" in
		zfw)     url="$GW/v2/zfw/api/health" ;;
		cron)    url="$GW/cron/health" ;;
		zbackup) url="$GW/v2/zbackup/api/health" ;;
		tailscale)
			f=/usr/lib/extension-release.d/extension-release.tailscale
			[ -r "$f" ] || return 1
			sed -n 's/^SYSEXT_VERSION_ID=//p' "$f" | head -n1
			return ;;
		mergerfs)
			[ -n "${2:-}" ] && [ -f /var/lib/extensions/mergerfs-snapraid.raw ] || return 1
			f="$WORK/mergerfs-SHA256SUMS"
			[ -s "$f" ] || curl -fsSL -m 20 -o "$f" \
				"https://github.com/chicohaager/zimaos-mergerfs-snapraid-sysext/releases/download/$2/SHA256SUMS" 2>/dev/null || return 1
			sum="$(sha256sum /var/lib/extensions/mergerfs-snapraid.raw | cut -d' ' -f1)"
			grep -q "^$sum  mergerfs-snapraid_$ARCH.raw\$" "$f" && echo "${2#v}"
			return ;;
	esac
	curl -fsS -m 5 "$url" -o "$WORK/health-$1.json" 2>/dev/null || return 1
	json_field "$WORK/health-$1.json" version
}

# is_present NAME — the module exists on disk even when its daemon is down
is_present() { [ -f "/var/lib/extensions/$(raw_name "$1").raw" ]; }

# version_by_file NAME — the version comes from the image, not from a daemon;
# an image there with no readable version is a build we cannot place
version_by_file() { case "$1" in mergerfs|tailscale) true ;; *) false ;; esac; }

# tailnet_ssh — an SSH session reaches this host over the tailnet (CGNAT
# 100.64.0.0/10 or Tailscale's fd7a:115c:a1e0::/48); restarting tailscaled
# drops it, and with it this script half-way through
tailnet_ssh() {
	ss -Htn state established '( sport = :22 )' 2>/dev/null | awk '{print $3}' |
		grep -qE '^(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|\[fd7a:115c:a1e0:)'
}

# fetch URL FILE — download with a size check (GitHub answers 404 with a page)
fetch() {
	curl -fsSL -m 600 --retry 3 -o "$2" "$1" || die "download failed: $1"
	[ -s "$2" ] || die "empty download: $1"
}

# wait_version NAME VERSION — up to 40 s for the daemon to report VERSION
wait_version() {
	local v
	for _ in $(seq 1 40); do
		v="$(installed_version "$1" || true)"
		[ "$v" = "$2" ] && return 0
		sleep 1
	done
	return 1
}

# semver_lt A B — true when A < B (like 1.2.3, 1.2.3-dev7, 1.2.3+build).
# A pre-release is older than its release (0.3.0-dev7 < 0.3.0); sort -V
# alone puts it after, and a box on a dev build never took the release.
# Build metadata carries no order. Two pre-releases of the same version
# count up naturally (dev7 < dev10), not by semver's ASCII rule.
semver_lt() {
	local a="${1%%+*}" b="${2%%+*}" ac bc ap bp first
	ac="${a%%-*}" bc="${b%%-*}"
	ap="${a#"$ac"}" bp="${b#"$bc"}"
	if [ "$ac" != "$bc" ]; then
		first="$(printf '%s\n%s\n' "$ac" "$bc" | sort -V)"
		[ "${first%%$'\n'*}" = "$ac" ]
		return
	fi
	[ "$ap" = "$bp" ] && return 1
	[ -z "$ap" ] && return 1  # release vs. its pre-release
	[ -z "$bp" ] && return 0  # pre-release vs. its release
	first="$(printf '%s\n%s\n' "$ap" "$bp" | sort -V)"
	[ "${first%%$'\n'*}" = "$ap" ]
}

# --- per-module installers ------------------------------------------------
install_raw() { # NAME TAG  — cron and zbackup: <name>-<arch>.raw via zpkg
	local name="$1" tag="$2" ver="${2#v}" base asset
	base="https://github.com/chicohaager/$3/releases/download/$tag"
	asset="$name-$ARCH.raw"
	say "$name: downloading $asset ($tag)"
	fetch "$base/$asset" "$WORK/$asset"
	fetch "$base/$asset.sha256" "$WORK/$asset.sha256"
	( cd "$WORK" && sha256sum -c "$asset.sha256" >/dev/null ) || die "$name: checksum mismatch"
	say "$name: checksum OK"
	mv "$WORK/$asset" "$WORK/$name.raw"   # zpkg matches the file name against the module name
	if is_present "$name"; then
		say "$name: removing the installed module (data under /DATA/AppData/$name is kept)"
		zpkg remove "$name" >/dev/null 2>&1 || warn "$name: zpkg remove reported an error, trying to install anyway"
	fi
	say "$name: zpkg install"
	zpkg install "$WORK/$name.raw" 2>&1 | sed 's/^/[lintux]   /'
	if wait_version "$name" "$ver"; then
		say "$name: $ver is running"
	else
		die "$name: installed, but the daemon does not report $ver within 40 s — check: systemctl status $name"
	fi
}

install_zfw() { # TAG — tarball with its own install.sh
	local tag="$1" ver="${1#v}" base asset
	base="https://github.com/chicohaager/zfw/releases/download/$tag"
	asset="zfw-$ver-$ARCH.tar.gz"
	say "zfw: downloading $asset ($tag)"
	fetch "$base/$asset" "$WORK/$asset"
	fetch "$base/$asset.sha256" "$WORK/$asset.sha256"
	( cd "$WORK" && sha256sum -c "$asset.sha256" >/dev/null ) || die "zfw: checksum mismatch"
	say "zfw: checksum OK"
	mkdir -p "$WORK/zfw" && tar xzf "$WORK/$asset" -C "$WORK/zfw"
	local dir; dir="$(find "$WORK/zfw" -maxdepth 2 -name install.sh | head -n1)"
	[ -n "$dir" ] || die "zfw: install.sh not found in $asset"
	say "zfw: running the module's install.sh"
	( cd "$(dirname "$dir")" && sh install.sh ) 2>&1 | sed 's/^/[lintux]   /'
	if wait_version zfw "$ver"; then
		say "zfw: $ver is running"
	else
		die "zfw: installed, but the daemon does not report $ver within 40 s — check: systemctl status zfw-ui"
	fi
}

# source_tree NAME TAG REPO — unpack the release's source archive, print its dir
source_tree() {
	local name="$1" tag="$2" repo="$3" dir
	fetch "https://github.com/chicohaager/$repo/archive/refs/tags/$tag.tar.gz" "$WORK/$name-src.tar.gz"
	mkdir -p "$WORK/$name-src"
	tar xzf "$WORK/$name-src.tar.gz" -C "$WORK/$name-src" || die "$name: cannot unpack the source archive"
	dir="$(find "$WORK/$name-src" -mindepth 1 -maxdepth 1 -type d | head -n1)"
	[ -f "$dir/install.sh" ] || die "$name: install.sh not found in the $tag source archive"
	echo "$dir"
}

install_mergerfs() { # TAG — image from the release, scripts and units from its source
	local tag="$1" base src asset
	base="https://github.com/chicohaager/zimaos-mergerfs-snapraid-sysext/releases/download/$tag"
	asset="mergerfs-snapraid_$ARCH.raw"
	say "mergerfs: downloading $asset ($tag)"
	src="$(source_tree mergerfs "$tag" zimaos-mergerfs-snapraid-sysext)" || exit 1
	mkdir -p "$src/build/out"
	fetch "$base/$asset" "$src/build/out/$asset"
	[ -s "$WORK/mergerfs-SHA256SUMS" ] || fetch "$base/SHA256SUMS" "$WORK/mergerfs-SHA256SUMS"
	grep "  $asset\$" "$WORK/mergerfs-SHA256SUMS" > "$src/build/out/SHA256SUMS"
	( cd "$src/build/out" && sha256sum -c SHA256SUMS >/dev/null ) || die "mergerfs: checksum mismatch"
	say "mergerfs: checksum OK"
	say "mergerfs: running the module's install.sh (pool.env and snapraid.conf are kept)"
	( cd "$src" && sh install.sh ) 2>&1 | sed 's/^/[lintux]   /'
	if [ "$(installed_version mergerfs "$tag")" = "${tag#v}" ] && [ -x /usr/bin/snapraid ]; then
		say "mergerfs: ${tag#v} is installed and merged"
	else
		die "mergerfs: installed, but the image in /var/lib/extensions is not the $tag release or snapraid is missing — check: systemd-sysext status"
	fi
}

install_tailscale() { # TAG — prebuilt image from the release, units and installer from its source
	local tag="$1" ver="${1#v}" base src asset
	base="https://github.com/chicohaager/zimaos-tailscale-sysext/releases/download/$tag"
	asset="tailscale-$ARCH.raw"
	say "tailscale: downloading $asset ($tag)"
	src="$(source_tree tailscale "$tag" zimaos-tailscale-sysext)" || exit 1
	fetch "$base/$asset" "$WORK/$asset"
	fetch "$base/$asset.sha256" "$WORK/$asset.sha256"
	( cd "$WORK" && sha256sum -c "$asset.sha256" >/dev/null ) || die "tailscale: checksum mismatch"
	say "tailscale: checksum OK"
	say "tailscale: running the module's install.sh (login state under /DATA/AppData/tailscale is kept; the tailnet drops for ~2 s)"
	( cd "$src" && TAILSCALE_RAW="$WORK/$asset" bash install.sh </dev/null ) 2>&1 | sed 's/^/[lintux]   /'
	if [ "$(installed_version tailscale)" = "$ver" ] && systemctl is-active --quiet tailscaled.service; then
		say "tailscale: $ver is running"
	else
		die "tailscale: installed, but $ver is not merged or tailscaled is not active — check: systemctl status tailscaled"
	fi
}

# --- main ------------------------------------------------------------------
wanted() { [ -z "$ONLY" ] || case ",$ONLY," in *",$1,"*) true ;; *) false ;; esac; }
asked()  { case ",$ADD," in *",$1,"*) true ;; *) false ;; esac; }

say "ZimaOS ${VERSION_ID:-?} · $ARCH · $( [ $CHECK = 1 ] && echo 'check only' || echo 'install/update' )${STACK:+ · stack: ${STACK//,/ }}"
rc=0
# tailscale last: its restart drops the tailnet for ~2 s, nothing should follow
for spec in "zfw:zfw" "cron:cron" "zbackup:zima-backup" \
	"mergerfs:zimaos-mergerfs-snapraid-sysext" "tailscale:zimaos-tailscale-sysext"; do
	name="${spec%%:*}"; repo="${spec#*:}"
	wanted "$name" || continue
	tag="$(latest_tag "$repo" || true)"
	if [ -z "$tag" ]; then
		err="$(tr '\n' ' ' <"$WORK/latest-$repo.err" 2>/dev/null)"
		warn "$name: cannot read the latest release from GitHub (${err:-answer without tag_name}) — skipped"
		rc=1; continue
	fi
	latest="${tag#v}"
	have="$(installed_version "$name" "$tag" || true)"
	if [ -n "$have" ]; then
		state="installed $have"
	elif is_present "$name" && version_by_file "$name"; then
		state="present on disk, not a build of release $latest (version unknown)"
	elif is_present "$name"; then
		state="present on disk, daemon not answering"
	else
		state="not installed"
	fi
	say "$name: $state · latest $latest"
	if [ $CHECK = 1 ]; then continue; fi

	if [ -z "$have" ] && ! is_present "$name" && ! asked "$name"; then
		say "$name: not installed and not asked for — add it with:  $0 --install $name"
		continue
	fi
	if [ "$have" = "$latest" ] && [ $FORCE = 0 ]; then
		say "$name: up to date"
		continue
	fi
	# An image we cannot place may be a newer own build — replaced only on request
	if [ -z "$have" ] && version_by_file "$name" && ! asked "$name" && [ $FORCE = 0 ]; then
		say "$name: left alone, its version is unknown — replace it with the release:  $0 --install $name"
		continue
	fi
	if [ -n "$have" ] && ! semver_lt "$have" "$latest" && [ $FORCE = 0 ]; then
		say "$name: installed $have is newer than the release $latest — left alone (use --force to replace)"
		continue
	fi
	if [ "$name" = zbackup ] && [ -n "$have" ] && [ $FORCE = 0 ]; then
		running="$(json_field "$WORK/health-zbackup.json" jobs_running)"
		if [ "${running:-0}" != "0" ]; then
			warn "zbackup: $running job(s) running — not touched now, run again later (or --force)"
			rc=1; continue
		fi
	fi
	if [ "$name" = mergerfs ] && [ $FORCE = 0 ] && pgrep -x snapraid >/dev/null 2>&1; then
		warn "mergerfs: snapraid is running (sync or scrub) — not touched now, run again later (or --force)"
		rc=1; continue
	fi
	if [ "$name" = tailscale ] && [ $FORCE = 0 ] && tailnet_ssh; then
		warn "tailscale: an SSH session reaches this host over the tailnet — the restart would cut it and this script with it; run from the LAN (or --force)"
		rc=1; continue
	fi
	case "$name" in
		zfw)       install_zfw "$tag" ;;
		cron)      install_raw cron "$tag" cron ;;
		zbackup)   install_raw zbackup "$tag" zima-backup ;;
		mergerfs)  install_mergerfs "$tag" ;;
		tailscale) install_tailscale "$tag" ;;
	esac
done
[ $CHECK = 1 ] && say "nothing changed (--check)"
exit $rc
