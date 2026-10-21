#!/bin/sh
# Prueft eine sysext-Wurzel (und optional Installer-Skripte) auf die Fallen, die
# ZimaOS-Module wirklich getroffen haben. Jede Regel nennt ihren Abschnitt in
# ZIMAOS-KNOWLEDGE.md.
#
#   sh lint-units.sh <rootfs-dir> [installer.sh ...]
#
# Ausgabe: "ERROR <datei>: <text>" / "WARN <datei>: <text>". Exit 1 bei mindestens
# einem ERROR, sonst 0. WARN bricht nichts ab.
set -u
ROOT="${1:?rootfs-Verzeichnis angeben}"; shift
[ -d "$ROOT" ] || { echo "ERROR $ROOT: kein Verzeichnis"; exit 1; }
errors=0
err()  { echo "ERROR $1: $2"; errors=$((errors + 1)); }
warn() { echo "WARN $1: $2"; }

# Abschnitt einer Zeile: awk merkt sich die letzte [Section].
in_section() {  # <datei> <schluessel> -> Abschnitte, in denen der Schluessel steht
  awk -v k="$2" '/^\[/{s=$0} $0 ~ "^"k"=" {print s}' "$1"
}

found_units=0
for u in "$ROOT"/usr/lib/systemd/system/*.service; do
  [ -f "$u" ] || continue
  found_units=$((found_units + 1))
  n=$(basename "$u")
  # L1 (§42): /DATA ist ein spaetes Bind-Mount - wer es benutzt, muss darauf warten.
  if grep -qE '^(ExecStart|ExecStartPre|ExecStartPost|Environment|WorkingDirectory|ReadWritePaths|ReadOnlyPaths)=.*/DATA' "$u"; then
    grep -qE '^RequiresMountsFor=.*/DATA' "$u" \
      || err "$n" "benutzt /DATA, hat aber kein RequiresMountsFor=/DATA/... (KB §42: startet sonst vor dem Mount)"
  fi
  # L2 (§18.9): StartLimit* gehoert nach [Unit]; unter [Service] ignoriert systemd es still.
  for k in StartLimitIntervalSec StartLimitBurst; do
    if in_section "$u" "$k" | grep -qv '^\[Unit\]$'; then
      err "$n" "$k steht nicht unter [Unit] - dort wirkungslos (systemd-analyze: Unknown key)"
    fi
  done
  # L5 (§18.9): WantedBy=multi-user.target in einer sysext startet beim Boot NICHT von selbst.
  # Kein WARN, wenn das Binary aus ExecStart watchdog.Install enthaelt: es legt die Units selbst
  # an. Das Paketsymbol uebersteht -s -w (gemessen an cron, zbackupd, modmanager, 21.10.2026).
  if grep -qE '^WantedBy=.*multi-user\.target' "$u"; then
    bin=$(sed -n 's/^ExecStart=[-@+!:]*\([^ ]*\).*/\1/p' "$u" | head -n 1)
    if [ -n "$bin" ] && [ -f "$ROOT$bin" ] && grep -aq 'lintux-modkit/watchdog\.Install' "$ROOT$bin"; then
      :
    else
      warn "$n" "startet beim Boot nicht von selbst (sysext-Race, §18.9) - Watchdog aus lintux-modkit/watchdog noetig"
    fi
  fi
done
[ "$found_units" -gt 0 ] || warn "$ROOT" "keine .service-Unit unter usr/lib/systemd/system"

# L4 (§7.4): ARCHITECTURE fehlt -> eine falsche Architektur scheitert erst beim Ausfuehren statt beim Merge.
rel=""
for f in "$ROOT"/usr/lib/extension-release.d/extension-release.*; do
  if [ -f "$f" ]; then rel="$f"; break; fi
done
if [ -z "$rel" ]; then
  warn "$ROOT" "kein extension-release (build-sysext.sh schreibt ihn)"
elif ! grep -q '^ARCHITECTURE=' "$rel"; then
  warn "$(basename "$rel")" "ohne ARCHITECTURE= (build-sysext.sh setzt es je Architektur)"
fi

# L3 (§18.9): `enable --now` auf einen Dienst startet bei einem Upgrade NICHT neu - das alte Binary liefe weiter.
for s in "$@"; do
  [ -f "$s" ] || { err "$s" "Installer nicht gefunden"; continue; }
  grep -nE 'systemctl[^#]*enable[^#]*--now[^#]*\.service' "$s" | while IFS= read -r line; do
    echo "ERROR $(basename "$s"):${line%%:*}: enable --now auf einen Dienst - bei Upgrades restart verwenden"
  done
  c=$(grep -cE 'systemctl[^#]*enable[^#]*--now[^#]*\.service' "$s")
  errors=$((errors + c))
done

[ "$errors" -eq 0 ] && exit 0 || exit 1
