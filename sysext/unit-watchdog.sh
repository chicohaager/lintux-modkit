#!/bin/sh
# Boot-Watchdog fuer einen Dienst aus einer sysext - Shell-Gegenstueck zu watchdog.Install
# fuer Module ohne eigenes Go-Binary (z. B. gebuendelte Fremdprogramme, Template-Instanzen).
#
#   sh unit-watchdog.sh enable  <unit> [boot-delay-sec]   Units schreiben, Timer an, Dienst starten
#   sh unit-watchdog.sh disable <unit>                    Timer aus, Units entfernen, Dienst stoppen
#   sh unit-watchdog.sh status  <unit>
#
#   <unit>  voller Name, z. B. nebula.service oder wireguard@wg0.service
#
# Warum: Units in einer sysext werden beim Boot nicht eingeplant (multi-user.target ist aufgeloest,
# bevor /usr gemerged ist - ZIMAOS-KNOWLEDGE §18.9, auf 1.8.0 weiter so, §70). Ein Timer in dem
# persistenten /etc/systemd/system startet den Dienst OnBootSec spaeter, falls er nicht laeuft.
# Ein "-refresh.path" wie in watchdog.Install fehlt mit Absicht: nach `zpkg install --force`
# feuerte PathChanged nicht (gemessen 1.8.0, §7.4.1).
#
# Namen: <basis>-watchdog.{service,timer}, <basis> = Unit ohne Endung, "@" durch "-" ersetzt -
# ein "@" im Namen machte die Watchdog-Unit selbst zu einer Template-Instanz.
#
# Fuer Tests: WATCHDOG_UNIT_DIR (Standard /etc/systemd/system), WATCHDOG_SYSTEMCTL (Standard systemctl).
set -eu
CMD="${1:?enable|disable|status}"; UNIT="${2:?unit}"; DELAY="${3:-15}"
case "$UNIT" in
  *.service) ;;
  *) echo "Unit muss auf .service enden: $UNIT" >&2; exit 2 ;;
esac
case "${UNIT%.service}" in *[!a-zA-Z0-9_@.-]*|"") echo "ungueltiger Unit-Name: $UNIT" >&2; exit 2 ;; esac
case "$DELAY" in *[!0-9]*|"") echo "ungueltige Verzoegerung: $DELAY" >&2; exit 2 ;; esac
BASE=$(printf '%s' "${UNIT%.service}" | tr '@' '-')
D="${WATCHDOG_UNIT_DIR:-/etc/systemd/system}"
SC="${WATCHDOG_SYSTEMCTL:-systemctl}"
if [ "$CMD" != status ] && [ -z "${WATCHDOG_UNIT_DIR:-}" ] && [ "$(id -u)" -ne 0 ]; then echo "braucht root" >&2; exit 1; fi

case "$CMD" in
enable)
  cat > "$D/$BASE-watchdog.service" <<EOF
[Unit]
Description=Start $UNIT if it is not running

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'systemctl is-active --quiet $UNIT || systemctl start $UNIT'
EOF
  cat > "$D/$BASE-watchdog.timer" <<EOF
[Unit]
Description=Start $UNIT if the sysext unit was missed at boot

[Timer]
OnBootSec=$DELAY

[Install]
WantedBy=timers.target
EOF
  $SC daemon-reload
  $SC enable "$BASE-watchdog.timer"
  $SC restart "$UNIT"
  echo "$UNIT: Watchdog an ($D/$BASE-watchdog.timer, OnBootSec=$DELAY), Dienst gestartet"
  ;;
disable)
  n=0
  if [ -f "$D/$BASE-watchdog.timer" ]; then $SC disable --now "$BASE-watchdog.timer" || true; fi
  for f in "$BASE-watchdog.service" "$BASE-watchdog.timer"; do
    if [ -f "$D/$f" ]; then rm -f "$D/$f"; n=$((n + 1)); fi
  done
  $SC stop "$UNIT" || true
  [ "$n" -eq 0 ] || $SC daemon-reload
  echo "$UNIT: gestoppt, $n Watchdog-Unit(s) entfernt"
  ;;
status)
  if [ -f "$D/$BASE-watchdog.timer" ]; then w=an; else w=aus; fi
  a=$($SC is-active "$UNIT" 2>/dev/null || true)
  echo "$UNIT: ${a:-unbekannt}, Watchdog $w"
  ;;
*) echo "unbekannter Befehl: $CMD (enable|disable|status)" >&2; exit 2 ;;
esac
