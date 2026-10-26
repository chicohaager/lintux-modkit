#!/bin/sh
# Faelle fuer sysext/appdata-guard.sh in Wegwerf-Ordnern (laeuft ohne root: APPDATA_GUARD_UID = eigene uid).
set -u
cd "$(dirname "$0")/.." || exit 2
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
chmod 755 "$T"
export APPDATA_GUARD_UID
APPDATA_GUARD_UID=$(id -u)
F=0
case_() { # name, erwarteter rc, ordner, Text in der Ausgabe
  out=$(sh sysext/appdata-guard.sh "$3" 2>&1); rc=$?
  case "$rc:$out" in "$2:"*"$4"*) echo "ok   $1" ;; *) echo "FAIL $1: rc=$rc, erwartet $2 und \"$4\": $out"; F=$((F + 1)) ;; esac
}
mkdir "$T/a" && chmod 777 "$T/a"
case_ "neuer Ordner, Eltern 0777" 0 "$T/a/wireguard" ""
if [ "$(stat -c %a "$T/a")" = 1777 ]; then echo "ok   Sticky-Bit gesetzt"; else echo "FAIL Sticky-Bit: $(stat -c %a "$T/a")"; F=$((F + 1)); fi
if [ "$(stat -c %a "$T/a/wireguard")" = 700 ]; then echo "ok   Ordner 0700"; else echo "FAIL Ordner: $(stat -c %a "$T/a/wireguard")"; F=$((F + 1)); fi
mkdir "$T/b" && chmod 755 "$T/b" && ln -s "$T/a" "$T/b/nebula"
case_ "Ordner ist ein Symlink" 1 "$T/b/nebula" "ist ein Symlink"
mkdir -m 777 "$T/b/zfw" && chmod 777 "$T/b/zfw"
case_ "andere duerfen in den Ordner schreiben" 1 "$T/b/zfw" "andere duerfen in $T/b/zfw schreiben"
mkdir "$T/c" && chmod 777 "$T/c" && mkdir "$T/c/AppData" && chmod 755 "$T/c/AppData"
case_ "Vorfahr 0777 ohne Sticky" 1 "$T/c/AppData/x" "$T/c (Modus 777)"
out=$(sh sysext/appdata-guard.sh --no-create "$T/a/neu" 2>&1); rc=$?
if [ "$rc" = 1 ] && [ ! -e "$T/a/neu" ] && [ "${out#*fehlt}" != "$out" ]; then echo "ok   --no-create: fehlender Ordner verweigert, nicht angelegt"; else echo "FAIL --no-create: rc=$rc, angelegt=$([ -e "$T/a/neu" ] && echo ja || echo nein): $out"; F=$((F + 1)); fi
out=$(sh sysext/appdata-guard.sh --no-create "$T/a/wireguard" 2>&1); rc=$?
if [ "$rc" = 0 ]; then echo "ok   --no-create: vorhandener Ordner geht"; else echo "FAIL --no-create vorhandener Ordner: rc=$rc $out"; F=$((F + 1)); fi
case_ "Weg nicht lesbar (fehlender Vorfahr)" 1 "$T/fehlt/AppData/x" "nicht lesbar"
export APPDATA_GUARD_PATH_UID="$APPDATA_GUARD_UID"
APPDATA_GUARD_UID=4242
case_ "Ordner gehoert jemand anderem" 1 "$T/a/wireguard" "$T/a/wireguard gehoert uid"
if [ $F = 0 ]; then echo "✓ appdata-guard: 10 Faelle"; else echo "✗ appdata-guard: $F Fehler"; fi
exit $F
