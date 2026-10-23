#!/bin/bash
# Tests fuer sysext/unit-watchdog.sh gegen ein Unit-Verzeichnis im Temp und ein systemctl,
# das nur mitschreibt. Jede Eigenschaft hat einen Fall, der sie verletzt sehen wuerde.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$HERE/sysext/unit-watchdog.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
mkdir -p "$T/units"
cat > "$T/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$T/log"
if [ "\$1" = is-active ]; then echo active; fi
exit 0
EOF
chmod +x "$T/systemctl"
run() { WATCHDOG_UNIT_DIR="$T/units" WATCHDOG_SYSTEMCTL="$T/systemctl" sh "$W" "$@"; }
has() { grep -qxF -- "$2" "$1"; }
t() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
count() { find "$T/units" -type f | wc -l; }

# enable: Template-Instanz -> Basisname ohne "@", beide Units, Reihenfolge der systemctl-Aufrufe
: > "$T/log"
if run enable wireguard@wg0.service >/dev/null; then ok "enable rc 0"; else bad "enable rc"; fi
t "beide Units unter wireguard-wg0-watchdog.*" test -f "$T/units/wireguard-wg0-watchdog.timer" -a -f "$T/units/wireguard-wg0-watchdog.service"
t "kein @ im Dateinamen" test -z "$(find "$T/units" -name '*@*')"
t "OnBootSec=15 als Standard" has "$T/units/wireguard-wg0-watchdog.timer" "OnBootSec=15"
t "Timer an timers.target" has "$T/units/wireguard-wg0-watchdog.timer" "WantedBy=timers.target"
t "Watchdog startet genau die Instanz" has "$T/units/wireguard-wg0-watchdog.service" "ExecStart=/bin/sh -c 'systemctl is-active --quiet wireguard@wg0.service || systemctl start wireguard@wg0.service'"
t "systemctl: reload, enable timer, restart Dienst" test "$(tr '\n' ';' < "$T/log")" = "daemon-reload;enable wireguard-wg0-watchdog.timer;restart wireguard@wg0.service;"

# eigene Verzoegerung
run enable nebula.service 40 >/dev/null
t "OnBootSec=40 uebernommen" has "$T/units/nebula-watchdog.timer" "OnBootSec=40"

# status
out=$(run status nebula.service); case "$out" in *"Watchdog an"*) ok "status an" ;; *) bad "status: $out" ;; esac

# disable: Timer aus, nur die eigenen Units weg, Dienst gestoppt; fremde Datei bleibt
touch "$T/units/fremd.service"; : > "$T/log"
run disable wireguard@wg0.service >/dev/null
t "disable entfernt beide Units" test ! -e "$T/units/wireguard-wg0-watchdog.timer" -a ! -e "$T/units/wireguard-wg0-watchdog.service"
t "fremde und andere Units bleiben" test -f "$T/units/fremd.service" -a -f "$T/units/nebula-watchdog.timer"
t "disable: Timer aus" has "$T/log" "disable --now wireguard-wg0-watchdog.timer"
t "disable: Dienst gestoppt" has "$T/log" "stop wireguard@wg0.service"
out=$(run status wireguard@wg0.service); case "$out" in *"Watchdog aus"*) ok "status aus" ;; *) bad "status: $out" ;; esac

# ungueltige Eingaben: Exit 2, nichts geschrieben
before=$(count)
for args in "enable nebula" "enable a;b.service" "enable x.service 1s" "enable ../x.service" "frobnicate nebula.service"; do
  # shellcheck disable=SC2086
  run $args >/dev/null 2>&1; rc=$?
  t "abgelehnt: $args (rc $rc)" test "$rc" -eq 2
done
t "ungueltige Aufrufe schreiben nichts" test "$(count)" -eq "$before"

# status braucht kein root (Lesen); enable ohne root wird abgelehnt - Pruefung nur ausserhalb des Test-Verzeichnisses
if [ "$(id -u)" -ne 0 ]; then
  out=$(WATCHDOG_SYSTEMCTL="$T/systemctl" sh "$W" status nebula.service 2>&1); rc=$?
  t "status ohne root (rc $rc: $out)" test "$rc" -eq 0
  WATCHDOG_SYSTEMCTL="$T/systemctl" sh "$W" enable nebula.service >/dev/null 2>&1; rc=$?
  t "enable ohne root abgelehnt (rc $rc)" test "$rc" -eq 1
fi

echo "unit-watchdog: $pass ok, $fail FAIL"
[ "$fail" -eq 0 ]
