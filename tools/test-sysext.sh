#!/bin/bash
# Tests fuer sysext/lint-units.sh und sysext/build-sysext.sh.
# Jede Lint-Regel wird gegen einen Fall gefahren, der anschlagen MUSS, und gegen
# einen, der es nicht darf - eine Pruefung, die nur ein Ergebnis kennt, misst nichts.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$HERE/sysext/lint-units.sh"
BUILD="$HERE/sysext/build-sysext.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

mkroot() {  # <dir> <unit-inhalt>
  mkdir -p "$1/usr/lib/systemd/system" "$1/usr/bin"
  printf '%s\n' "$2" > "$1/usr/lib/systemd/system/demo.service"
  printf '#!/bin/sh\n' > "$1/usr/bin/demo"
}

GOOD='[Unit]
Description=demo
RequiresMountsFor=/DATA/AppData/demo
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/bin/demo
Environment=DATA_DIR=/DATA/AppData/demo
Restart=always

[Install]
WantedBy=multi-user.target'

expect() {  # <name> <erwartet: 0|1> <muster|""> <args...>
  local name="$1" want="$2" pat="$3"; shift 3
  local out rc
  out=$(sh "$LINT" "$@" 2>&1); rc=$?
  if [ "$rc" -ne "$want" ]; then bad "$name (exit $rc, erwartet $want): $out"; return; fi
  if [ -n "$pat" ] && ! printf '%s' "$out" | grep -q "$pat"; then bad "$name (Meldung fehlt: $pat): $out"; return; fi
  ok "$name"
}

mkroot "$T/good" "$GOOD"
expect "saubere Unit: kein ERROR" 0 "" "$T/good"
expect "saubere Unit: Boot-Race-Hinweis kommt als WARN" 0 "WARN demo.service: startet beim Boot nicht" "$T/good"

mkroot "$T/nomount" "${GOOD/RequiresMountsFor=\/DATA\/AppData\/demo
/}"
expect "L1 /DATA ohne RequiresMountsFor -> ERROR" 1 "kein RequiresMountsFor" "$T/nomount"

mkroot "$T/startlimit" "${GOOD/StartLimitIntervalSec=0
/}
StartLimitIntervalSec=0"
# Anhang landet unter [Install] - eine Variante unter [Service] gleich dazu:
mkroot "$T/startlimit2" "${GOOD/Restart=always/Restart=always
StartLimitIntervalSec=0}"
expect "L2 StartLimitIntervalSec unter [Install] -> ERROR" 1 "nicht unter \[Unit\]" "$T/startlimit"
expect "L2 StartLimitIntervalSec unter [Service] -> ERROR" 1 "nicht unter \[Unit\]" "$T/startlimit2"

printf '#!/bin/sh\nsystemctl enable --now demo.service\n' > "$T/inst-bad.sh"
printf '#!/bin/sh\nsystemctl enable demo.service\nsystemctl restart demo.service\nsystemctl enable --now demo-watchdog.timer\n' > "$T/inst-good.sh"
expect "L3 enable --now auf Dienst -> ERROR" 1 "inst-bad.sh:2: enable --now" "$T/good" "$T/inst-bad.sh"
expect "L3 enable --now auf Timer ist erlaubt" 0 "" "$T/good" "$T/inst-good.sh"

mkdir -p "$T/good/usr/lib/extension-release.d"; printf 'ID=_any\n' > "$T/good/usr/lib/extension-release.d/extension-release.demo"
expect "L4 ohne ARCHITECTURE -> WARN" 0 "ohne ARCHITECTURE" "$T/good"
rm -rf "$T/good/usr/lib/extension-release.d"

# --- Build ---------------------------------------------------------------
if SOURCE_DATE_EPOCH=1700000000 sh "$BUILD" demo "$T/good" amd64 "$T/out1" >/dev/null 2>&1 \
   && SOURCE_DATE_EPOCH=1700000000 sh "$BUILD" demo "$T/good" amd64 "$T/out2" >/dev/null 2>&1; then
  ok "Build amd64 laeuft"
  for f in demo-amd64.raw demo-amd64.raw.sha256 demo.raw demo.raw.sha256; do
    [ -f "$T/out1/$f" ] && ok "Asset $f vorhanden" || bad "Asset $f fehlt"
  done
  cmp -s "$T/out1/demo-amd64.raw" "$T/out2/demo-amd64.raw" && ok "Build ist reproduzierbar (byte-gleich)" || bad "zwei Builds unterscheiden sich"
  rel=$(unsquashfs -cat "$T/out1/demo-amd64.raw" usr/lib/extension-release.d/extension-release.demo 2>/dev/null)
  [ "$rel" = "$(printf 'ID=_any\nARCHITECTURE=x86-64')" ] && ok "extension-release im Image: ID=_any + ARCHITECTURE=x86-64" || bad "extension-release falsch: $rel"
  ( cd "$T/out1" && sha256sum -c --quiet demo.raw.sha256 ) && ok "sha256 des Plain-Namens stimmt" || bad "sha256 demo.raw stimmt nicht"
  [ ! -e "$T/good/usr/lib/extension-release.d" ] && ok "Quelle unangetastet" || bad "Build hat die Quelle veraendert"
else
  bad "Build amd64 scheiterte"
fi
if SOURCE_DATE_EPOCH=1700000000 sh "$BUILD" demo "$T/good" arm64 "$T/out3" >/dev/null 2>&1; then
  [ ! -e "$T/out3/demo.raw" ] && ok "arm64: kein Plain-Name (der gehoert amd64)" || bad "arm64 hat demo.raw erzeugt"
  rel=$(unsquashfs -cat "$T/out3/demo-arm64.raw" usr/lib/extension-release.d/extension-release.demo 2>/dev/null)
  printf '%s' "$rel" | grep -q '^ARCHITECTURE=arm64$' && ok "arm64: ARCHITECTURE=arm64" || bad "arm64-Release falsch: $rel"
else
  bad "Build arm64 scheiterte"
fi
if SOURCE_DATE_EPOCH=1 sh "$BUILD" demo "$T/nomount" amd64 "$T/out4" >/dev/null 2>&1; then
  bad "Build mit Lint-ERROR lief durch"
else
  [ ! -e "$T/out4/demo-amd64.raw" ] && ok "Lint-ERROR bricht den Build ab, kein Image" || bad "Lint-ERROR, aber Image erzeugt"
fi
sh "$BUILD" 'Demo!' "$T/good" amd64 "$T/out5" >/dev/null 2>&1 && bad "ungueltiger Name angenommen" || ok "ungueltiger Name abgelehnt"

echo "---- $pass ok, $fail FAIL"
[ "$fail" -eq 0 ]
