#!/bin/sh
# Faelle fuer sysext/appdata-guard.sh in Wegwerf-Ordnern (laeuft ohne root: APPDATA_GUARD_UID = eigene uid).
set -u
cd "$(dirname "$0")/.." || exit 2
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
chmod 755 "$T"
export APPDATA_GUARD_UID
APPDATA_GUARD_UID=$(id -u)
F=0 ok=0
case_() { # name, erwarteter rc, ordner, Text in der Ausgabe
  out=$(sh sysext/appdata-guard.sh "$3" 2>&1); rc=$?
  case "$rc:$out" in "$2:"*"$4"*) ok=$((ok + 1)); echo "ok   $1" ;; *) echo "FAIL $1: rc=$rc, erwartet $2 und \"$4\": $out"; F=$((F + 1)) ;; esac
}
mkdir "$T/a" && chmod 777 "$T/a"
case_ "neuer Ordner, Eltern 0777" 0 "$T/a/wireguard" ""
if [ "$(stat -c %a "$T/a")" = 1777 ]; then ok=$((ok + 1)); echo "ok   Sticky-Bit gesetzt"; else echo "FAIL Sticky-Bit: $(stat -c %a "$T/a")"; F=$((F + 1)); fi
if [ "$(stat -c %a "$T/a/wireguard")" = 700 ]; then ok=$((ok + 1)); echo "ok   Ordner 0700"; else echo "FAIL Ordner: $(stat -c %a "$T/a/wireguard")"; F=$((F + 1)); fi
mkdir "$T/b" && chmod 755 "$T/b" && ln -s "$T/a" "$T/b/nebula"
case_ "Ordner ist ein Symlink" 1 "$T/b/nebula" "ist ein Symlink"
mkdir -m 777 "$T/b/zfw" && chmod 777 "$T/b/zfw"
case_ "andere duerfen in den Ordner schreiben" 1 "$T/b/zfw" "andere duerfen in $T/b/zfw schreiben"
mkdir "$T/c" && chmod 777 "$T/c" && mkdir "$T/c/AppData" && chmod 755 "$T/c/AppData"
case_ "Vorfahr 0777 ohne Sticky" 1 "$T/c/AppData/x" "$T/c (Modus 777)"
out=$(sh sysext/appdata-guard.sh --no-create "$T/a/neu" 2>&1); rc=$?
if [ "$rc" = 1 ] && [ ! -e "$T/a/neu" ] && [ "${out#*fehlt}" != "$out" ]; then ok=$((ok + 1)); echo "ok   --no-create: fehlender Ordner verweigert, nicht angelegt"; else echo "FAIL --no-create: rc=$rc, angelegt=$([ -e "$T/a/neu" ] && echo ja || echo nein): $out"; F=$((F + 1)); fi
out=$(sh sysext/appdata-guard.sh --no-create "$T/a/wireguard" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok=$((ok + 1)); echo "ok   --no-create: vorhandener Ordner geht"; else echo "FAIL --no-create vorhandener Ordner: rc=$rc $out"; F=$((F + 1)); fi
case_ "Weg nicht lesbar (fehlender Vorfahr)" 1 "$T/fehlt/AppData/x" "nicht lesbar"
# Symlink im Weg (Forum 9566: /DATA/AppData als Symlink, "kein echter Ordner"): gefolgt wird einem Schritt auf
# einen echten Weg, der dann bis / geprueft wird
mkdir -m 755 "$T/e" "$T/e/platte" && mkdir -m 777 "$T/e/platte/AppData" && chmod 777 "$T/e/platte/AppData" && mkdir -m 755 "$T/e/DATA"
ln -s "$T/e/platte/AppData" "$T/e/DATA/AppData"
case_ "Elternordner Symlink auf sicheren Weg: gefolgt" 0 "$T/e/DATA/AppData/tailscale" "Symlink auf $T/e/platte/AppData"
if [ "$(stat -c %a "$T/e/platte/AppData")" = 1777 ] && [ "$(stat -c %a "$T/e/platte/AppData/tailscale")" = 700 ]; then ok=$((ok + 1)); echo "ok   Symlink: Sticky-Bit und Ordner 0700 am Ziel"; else echo "FAIL Symlink Ziel: $(stat -c %a "$T/e/platte/AppData") $(stat -c %a "$T/e/platte/AppData/tailscale" 2>&1)"; F=$((F + 1)); fi
mkdir -m 755 "$T/f" && mkdir -m 777 "$T/f/offen" && chmod 777 "$T/f/offen" && mkdir -m 755 "$T/f/offen/AppData" "$T/f/DATA"
ln -s "$T/f/offen/AppData" "$T/f/DATA/AppData"
case_ "Elternordner Symlink, Ziel unter 0777 ohne Sticky" 1 "$T/f/DATA/AppData/tailscale" "$T/f/offen (Modus 777)"
if [ ! -e "$T/f/offen/AppData/tailscale" ]; then ok=$((ok + 1)); echo "ok   unsicheres Ziel: nichts angelegt"; else echo "FAIL unsicheres Ziel: Ordner angelegt"; F=$((F + 1)); fi
ln -s "$T/e/DATA/AppData" "$T/f/DATA/kette"
case_ "Elternordner Symlink auf Symlink" 1 "$T/f/DATA/kette/x" "gefolgt wird nur einem Symlink"
ln -s "$T/e/gibtsnicht" "$T/f/DATA/tot"
case_ "Elternordner Symlink ins Leere" 1 "$T/f/DATA/tot/x" "das fehlt"
case_ "Elternordner fehlt" 1 "$T/e/DATA/fehlt/x" "$T/e/DATA/fehlt fehlt"
: > "$T/e/DATA/datei"
case_ "Elternordner ist eine Datei" 1 "$T/e/DATA/datei/x" "ist kein Ordner"
mkdir -m 755 "$T/f/offen/sub" "$T/f/offen/sub/AppData" && ln -s "$T/f/offen/sub" "$T/e/vorfahr"
case_ "Vorfahr Symlink auf 0755 unter 0777: Weg des Ziels geprueft" 1 "$T/e/vorfahr/AppData/x" "$T/f/offen (Modus 777)"
mkdir -m 755 "$T/g" "$T/g/platte" "$T/g/platte/AppData" "$T/g/DATA"
ln -s "$T/g/platte/AppData/" "$T/g/DATA/AppData" && ln -s "$T/g//platte//AppData" "$T/g/DATA/doppelt"
case_ "Symlink-Ziel mit / am Ende" 0 "$T/g/DATA/AppData/tailscale" "Symlink auf $T/g/platte/AppData "
case_ "Symlink-Ziel mit doppeltem /" 0 "$T/g/DATA/doppelt/cron" "Symlink auf $T/g/platte/AppData "
ln -s "../platte/AppData" "$T/g/DATA/relativ-punkt"
case_ "relatives Ziel mit .. bleibt verweigert" 1 "$T/g/DATA/relativ-punkt/x" "oder . und .."
ln -s "$T/e/platte" "$T/e/vorfahr-gut"
case_ "Vorfahr Symlink auf sicheren Weg" 0 "$T/e/vorfahr-gut/AppData/nebula" ""
# Faelle mit fremder uid: als root ist die eigene uid 0 immer vertrauenswuerdig, sie greifen nur ohne root
if [ "$(id -u)" != 0 ]; then
export APPDATA_GUARD_PATH_UID="$APPDATA_GUARD_UID"
APPDATA_GUARD_UID=4242
case_ "Ordner gehoert jemand anderem" 1 "$T/a/wireguard" "$T/a/wireguard gehoert uid"
# /DATA eines anderen: ohne root mit Ersatz-chown (Fehlschlag; "Erfolg" ohne Wirkung muss die Neumessung fangen)
mkdir -p "$T/d/AppData" && chmod 755 "$T/d" "$T/d/AppData"
out=$(APPDATA_GUARD_UID=0 APPDATA_GUARD_PATH_UID=4242 APPDATA_GUARD_DATA="$T/d" APPDATA_GUARD_CHOWN=false sh sysext/appdata-guard.sh "$T/d/AppData/cron" 2>&1); rc=$?
case "$rc:$out" in 1:*"Eigentuemer root nicht gesetzt"*) ok=$((ok + 1)); echo "ok   /DATA: chown scheitert, verweigert" ;; *) echo "FAIL /DATA chown scheitert: rc=$rc $out"; F=$((F + 1)) ;; esac
out=$(APPDATA_GUARD_UID=0 APPDATA_GUARD_PATH_UID=4242 APPDATA_GUARD_DATA="$T/d" APPDATA_GUARD_CHOWN=true sh sysext/appdata-guard.sh "$T/d/AppData/cron" 2>&1); rc=$?
case "$rc:$out" in 1:*"$T/d gehoert uid"*) ok=$((ok + 1)); echo "ok   /DATA: chown ohne Wirkung, Neumessung verweigert" ;; *) echo "FAIL /DATA chown ohne Wirkung: rc=$rc $out"; F=$((F + 1)) ;; esac
unset APPDATA_GUARD_PATH_UID
APPDATA_GUARD_UID=$(id -u)
fi
# mit root: echtes chown (laeuft auf dem Host, in der CI nicht)
if [ "$(id -u)" = 0 ]; then
  mkdir -p "$T/r/AppData" && chmod 755 "$T/r" "$T/r/AppData" && chown 4242:4243 "$T/r"
  out=$(APPDATA_GUARD_UID=0 APPDATA_GUARD_PATH_UID=0 APPDATA_GUARD_DATA="$T/r" sh sysext/appdata-guard.sh "$T/r/AppData/cron" 2>&1); rc=$?
  case "$rc:$(stat -c '%u:%g %a' "$T/r"):$out" in "0:0:0 755:"*"gehoerte uid 4242"*"chown 4242:4243 $T/r"*) ok=$((ok + 1)); echo "ok   root: /DATA repariert, Modus bleibt, Rueckweg genannt" ;; *) echo "FAIL root /DATA: rc=$rc $(stat -c '%u:%g %a' "$T/r") $out"; F=$((F + 1)) ;; esac
  mkdir -p "$T/q/AppData" && chmod 755 "$T/q" "$T/q/AppData" && chown 4242 "$T/q"
  out=$(APPDATA_GUARD_UID=0 APPDATA_GUARD_PATH_UID=0 APPDATA_GUARD_DATA="$T/r" sh sysext/appdata-guard.sh "$T/q/AppData/cron" 2>&1); rc=$?
  case "$rc:$(stat -c %u "$T/q"):$out" in 1:4242:*"$T/q gehoert uid 4242"*) ok=$((ok + 1)); echo "ok   root: anderer Vorfahr bleibt verweigert und unveraendert" ;; *) echo "FAIL root anderer Vorfahr: rc=$rc $(stat -c %u "$T/q") $out"; F=$((F + 1)) ;; esac
  mkdir -p "$T/s/AppData" && chmod 755 "$T/s/AppData" && ln -s "$T/s" "$T/sl" && chown -h 4242 "$T/sl" && chown 4242 "$T/s"
  out=$(APPDATA_GUARD_UID=0 APPDATA_GUARD_PATH_UID=0 APPDATA_GUARD_DATA="$T/sl" sh sysext/appdata-guard.sh "$T/sl/AppData/cron" 2>&1); rc=$?
  case "$rc:$(stat -c %u "$T/s"):$out" in 1:4242:*) ok=$((ok + 1)); echo "ok   root: /DATA als Symlink verweigert, nicht repariert" ;; *) echo "FAIL root Symlink: rc=$rc $(stat -c %u "$T/s") $out"; F=$((F + 1)) ;; esac
  # Symlink eines anderen: sein Eigentuemer biegt ihn nach der Pruefung um
  mkdir -p "$T/u/real/AppData" "$T/u/DATA" && chmod 755 "$T/u" "$T/u/real" "$T/u/real/AppData" "$T/u/DATA"
  ln -s "$T/u/real/AppData" "$T/u/DATA/AppData" && chown -h 4242 "$T/u/DATA/AppData"
  out=$(APPDATA_GUARD_UID=0 APPDATA_GUARD_PATH_UID=0 sh sysext/appdata-guard.sh "$T/u/DATA/AppData/x" 2>&1); rc=$?
  case "$rc:$out" in 1:*"Symlink von uid 4242"*) ok=$((ok + 1)); echo "ok   root: Elternordner-Symlink eines anderen verweigert" ;; *) echo "FAIL root fremder Symlink: rc=$rc $out"; F=$((F + 1)) ;; esac
  ln -s "$T/u/real" "$T/u/vorfahr" && chown -h 4242 "$T/u/vorfahr"
  out=$(APPDATA_GUARD_UID=0 APPDATA_GUARD_PATH_UID=0 sh sysext/appdata-guard.sh "$T/u/vorfahr/AppData/x" 2>&1); rc=$?
  case "$rc:$out" in 1:*"Symlink von uid 4242"*) ok=$((ok + 1)); echo "ok   root: Vorfahr-Symlink eines anderen verweigert" ;; *) echo "FAIL root fremder Vorfahr-Symlink: rc=$rc $out"; F=$((F + 1)) ;; esac
else
  echo "--   5 Faelle mit echtem chown uebersprungen (nicht root)"
fi
if [ $F = 0 ]; then echo "✓ appdata-guard: $ok Faelle"; else echo "✗ appdata-guard: $F Fehler"; fi
exit $F
