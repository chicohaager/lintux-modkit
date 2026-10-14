#!/bin/sh
# Shell-Gegenstueck zu watchdog.Uninstall fuer Deinstallations-Skripte:
#   sh uninstall-watchdog.sh <service>
# Entfernt genau die vier Units, die watchdog.Install schreibt, sonst nichts.
set -eu
S="${1:?service}"
case "$S" in *[!a-z0-9_-]*|"") echo "ungueltiger Dienstname: $S" >&2; exit 2 ;; esac
[ "$(id -u)" -eq 0 ] || { echo "braucht root" >&2; exit 1; }
D=/etc/systemd/system
for u in "$S-watchdog.timer" "$S-refresh.path"; do
  if [ -f "$D/$u" ]; then systemctl disable --now "$u" >/dev/null 2>&1 || true; fi
done
n=0
for f in "$S-watchdog.service" "$S-watchdog.timer" "$S-refresh.path" "$S-refresh.service"; do
  if [ -f "$D/$f" ]; then rm -f "$D/$f"; n=$((n + 1)); fi
done
[ "$n" -gt 0 ] && systemctl daemon-reload
echo "$S: $n Watchdog-Unit(s) entfernt"
