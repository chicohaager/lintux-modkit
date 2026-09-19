#!/bin/bash
# Writes the two ready-made installers from install.sh. Run after every
# change to install.sh; CI fails when the generated files are stale.
set -eu
cd "$(dirname "$0")/.."
gen() {
	local out="$1" stack="$2"
	sed -e "s|^STACK=\"\"$|STACK=\"$stack\"|" \
	    -e "s|^# install.sh — install or update the Lintux modules on a ZimaOS host:|# $out — generated from install.sh by tools/gen-installers.sh, do not edit.\\n# Installs or updates these Lintux modules on a ZimaOS host: ${stack//,/, }.|" \
	    install.sh > "$out"
	chmod 755 "$out"
	grep -q "^STACK=\"$stack\"$" "$out" || { echo "STACK line missing in $out" >&2; exit 1; }
}
gen install-with-firewall.sh    zfw,cron,zbackup
gen install-without-firewall.sh cron,zbackup
echo "generated install-with-firewall.sh install-without-firewall.sh"
