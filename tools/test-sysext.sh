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

absent() {  # <name> <muster> <args...>: Lint laeuft durch und die Meldung fehlt
  local name="$1" pat="$2"; shift 2
  local out
  out=$(sh "$LINT" "$@" 2>&1) || { bad "$name (exit $?): $out"; return; }
  if printf '%s' "$out" | grep -q "$pat"; then bad "$name (Meldung da: $pat): $out"; return; fi
  ok "$name"
}
mkroot "$T/wd" "$GOOD"
printf '#!/bin/sh\n# github.com/chicohaager/lintux-modkit/watchdog.Install\n' > "$T/wd/usr/bin/demo"
absent "L5 Binary installiert den Watchdog selbst -> kein WARN" "startet beim Boot nicht" "$T/wd"
mkroot "$T/wd2" "${GOOD/ExecStart=\/usr\/bin\/demo/ExecStart=-/usr/bin/demo --serve}"
cp "$T/wd/usr/bin/demo" "$T/wd2/usr/bin/demo"
absent "L5 ExecStart mit Praefix und Argument -> Binary gefunden" "startet beim Boot nicht" "$T/wd2"

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
    if [ -f "$T/out1/$f" ]; then ok "Asset $f vorhanden"; else bad "Asset $f fehlt"; fi
  done
  if cmp -s "$T/out1/demo-amd64.raw" "$T/out2/demo-amd64.raw"; then ok "Build ist reproduzierbar (byte-gleich)"; else bad "zwei Builds unterscheiden sich"; fi
  rel=$(unsquashfs -cat "$T/out1/demo-amd64.raw" usr/lib/extension-release.d/extension-release.demo 2>/dev/null)
  if [ "$rel" = "$(printf 'ID=_any\nARCHITECTURE=x86-64')" ]; then ok "extension-release im Image: ID=_any + ARCHITECTURE=x86-64"; else bad "extension-release falsch: $rel"; fi
  if ( cd "$T/out1" && sha256sum -c --quiet demo.raw.sha256 ); then ok "sha256 des Plain-Namens stimmt"; else bad "sha256 demo.raw stimmt nicht"; fi
  if [ ! -e "$T/good/usr/lib/extension-release.d" ]; then ok "Quelle unangetastet"; else bad "Build hat die Quelle veraendert"; fi
else
  bad "Build amd64 scheiterte"
fi
if SOURCE_DATE_EPOCH=1700000000 sh "$BUILD" demo "$T/good" arm64 "$T/out3" >/dev/null 2>&1; then
  if [ ! -e "$T/out3/demo.raw" ]; then ok "arm64: kein Plain-Name (der gehoert amd64)"; else bad "arm64 hat demo.raw erzeugt"; fi
  rel=$(unsquashfs -cat "$T/out3/demo-arm64.raw" usr/lib/extension-release.d/extension-release.demo 2>/dev/null)
  if printf '%s' "$rel" | grep -q '^ARCHITECTURE=arm64$'; then ok "arm64: ARCHITECTURE=arm64"; else bad "arm64-Release falsch: $rel"; fi
else
  bad "Build arm64 scheiterte"
fi
if SOURCE_DATE_EPOCH=1 sh "$BUILD" demo "$T/nomount" amd64 "$T/out4" >/dev/null 2>&1; then
  bad "Build mit Lint-ERROR lief durch"
else
  if [ ! -e "$T/out4/demo-amd64.raw" ]; then ok "Lint-ERROR bricht den Build ab, kein Image"; else bad "Lint-ERROR, aber Image erzeugt"; fi
fi
if sh "$BUILD" 'Demo!' "$T/good" amd64 "$T/out5" >/dev/null 2>&1; then bad "ungueltiger Name angenommen"; else ok "ungueltiger Name abgelehnt"; fi
if SOURCE_DATE_EPOCH=1700000000 sh "$BUILD" demo "$T/good" amd64 "$T/out6" v1.2.3-dev4 >/dev/null 2>&1; then
  rel=$(unsquashfs -cat "$T/out6/demo-amd64.raw" usr/lib/extension-release.d/extension-release.demo 2>/dev/null)
  if [ "$rel" = "$(printf 'ID=_any\nARCHITECTURE=x86-64\nSYSEXT_VERSION_ID=1.2.3-dev4')" ]; then ok "Version: SYSEXT_VERSION_ID ohne fuehrendes v"; else bad "Version falsch im Release: $rel"; fi
else
  bad "Build mit Version scheiterte"
fi
if sh "$BUILD" demo "$T/good" amd64 "$T/out7" '1.0;rm' >/dev/null 2>&1; then bad "ungueltige Version angenommen"; else ok "ungueltige Version abgelehnt"; fi

# Modul-JSON: ohne sie warnt der Build (zpkg meldet sonst rc=1), mit ihr nicht
out=$(SOURCE_DATE_EPOCH=1 sh "$BUILD" demo "$T/good" amd64 "$T/out8" 2>&1)
case "$out" in *"WARN demo: keine usr/share/casaos/modules/demo.json"*) ok "ohne Modul-JSON: WARN" ;; *) bad "ohne Modul-JSON keine WARN: $out" ;; esac
cp -a "$T/good" "$T/withjson"; mkdir -p "$T/withjson/usr/share/casaos/modules"
printf '{"name": "demo"}\n' > "$T/withjson/usr/share/casaos/modules/demo.json"
out=$(SOURCE_DATE_EPOCH=1 sh "$BUILD" demo "$T/withjson" amd64 "$T/out9" 2>&1)
case "$out" in *"modules/demo.json"*) bad "WARN trotz Modul-JSON: $out" ;; *) ok "mit Modul-JSON: keine WARN" ;; esac

# lintux-modkit-Stand im Image: Commit, +dirty bei geaenderter Kopie, "unbekannt" ausserhalb von git
modkit_in() {  # <out-dir>: Inhalt von usr/share/doc/demo/lintux-modkit.txt im Image
  unsquashfs -cat "$1/demo-amd64.raw" usr/share/doc/demo/lintux-modkit.txt 2>/dev/null
}
export GIT_CEILING_DIRECTORIES="$T"
mkdir -p "$T/mk/sysext"; cp "$HERE"/sysext/*.sh "$T/mk/sysext/"
git -C "$T/mk" init -q && git -C "$T/mk" add sysext \
  && git -C "$T/mk" -c user.name=t -c user.email=t@t commit -qm t
rev=$(git -C "$T/mk" rev-parse HEAD)
SOURCE_DATE_EPOCH=1 sh "$T/mk/sysext/build-sysext.sh" demo "$T/withjson" amd64 "$T/out10" >/dev/null 2>&1
got=$(modkit_in "$T/out10")
if [ "$got" = "lintux-modkit $rev" ]; then ok "lintux-modkit-Commit im Image"; else bad "lintux-modkit im Image: '$got', erwartet 'lintux-modkit $rev'"; fi
printf '# x\n' >> "$T/mk/sysext/add-web.sh"
SOURCE_DATE_EPOCH=1 sh "$T/mk/sysext/build-sysext.sh" demo "$T/withjson" amd64 "$T/out11" >/dev/null 2>&1
got=$(modkit_in "$T/out11")
if [ "$got" = "lintux-modkit $rev+dirty" ]; then ok "geaenderter lintux-modkit: +dirty im Image"; else bad "geaenderter lintux-modkit im Image: '$got'"; fi
mkdir -p "$T/nogit/sysext"; cp "$HERE"/sysext/*.sh "$T/nogit/sysext/"
SOURCE_DATE_EPOCH=1 sh "$T/nogit/sysext/build-sysext.sh" demo "$T/withjson" amd64 "$T/out12" >/dev/null 2>&1
got=$(modkit_in "$T/out12")
if [ "$got" = "lintux-modkit unbekannt" ]; then ok "lintux-modkit ohne git: unbekannt"; else bad "lintux-modkit ohne git: '$got'"; fi
unset GIT_CEILING_DIRECTORIES

# add-web.sh: version into HTML and module JSON, common files copied, broken JS refused
ADDWEB="$HERE/sysext/add-web.sh"
mkweb() {  # <dir> <js>
  mkdir -p "$1/usr/share/casaos/www/modules/demo" "$1/usr/share/casaos/modules"
  printf '<script src="./app.js?v=@VERSION@"></script>\n' > "$1/usr/share/casaos/www/modules/demo/index.html"
  printf '%s\n' "$2" > "$1/usr/share/casaos/www/modules/demo/app.js"
  printf '{"name": "demo", "version": "v@VERSION@"}\n' > "$1/usr/share/casaos/modules/demo.json.in"
}
mkweb "$T/web1" "const a = 1;"
if sh "$ADDWEB" demo "$T/web1" 2.0.1 >/dev/null 2>&1 \
   && grep -q 'app.js?v=2.0.1' "$T/web1/usr/share/casaos/www/modules/demo/index.html" \
   && grep -q '"version": "v2.0.1"' "$T/web1/usr/share/casaos/modules/demo.json" \
   && [ ! -e "$T/web1/usr/share/casaos/modules/demo.json.in" ] \
   && [ -f "$T/web1/usr/share/casaos/www/modules/demo/common.js" ]; then
  ok "add-web: Version eingesetzt, JSON erzeugt, common.js kopiert"
else
  bad "add-web: Ergebnis falsch"
fi
# every module with a tile gets the AppData guard for its units (ExecStartPre), executable for sh
if [ -f "$T/web1/usr/libexec/demo/appdata-guard.sh" ] && cmp -s "$HERE/sysext/appdata-guard.sh" "$T/web1/usr/libexec/demo/appdata-guard.sh"; then
  ok "add-web: appdata-guard.sh nach /usr/libexec/demo"
else
  bad "add-web: appdata-guard.sh fehlt in /usr/libexec/demo"
fi
mkweb "$T/web2" "const a = ;"
if sh "$ADDWEB" demo "$T/web2" 2.0.1 >/dev/null 2>&1; then bad "add-web: kaputtes JS angenommen"; else ok "add-web: kaputtes JS abgelehnt"; fi
mkweb "$T/web3" "const a = 1;"
printf '{"name": "other"}\n' > "$T/web3/usr/share/casaos/modules/demo.json.in"
if sh "$ADDWEB" demo "$T/web3" 2.0.1 >/dev/null 2>&1; then bad "add-web: falscher JSON-Name angenommen"; else ok "add-web: falscher JSON-Name abgelehnt"; fi

echo "---- $pass ok, $fail FAIL"
[ "$fail" -eq 0 ]
