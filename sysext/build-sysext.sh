#!/bin/sh
# Ein sysext-Image fuer ZimaOS bauen - fuer alle Module gleich.
#
#   sh build-sysext.sh <name> <rootfs-dir> <amd64|arm64> <out-dir> [version]
#
# Ergebnis in <out-dir>:
#   <name>-<arch>.raw (+ .sha256)   immer
#   <name>.raw        (+ .sha256)   nur fuer amd64: der Name, den zpkg ueber einen
#                                   `repo`-Katalogeintrag laedt (gemessen: <name>.raw aus
#                                   dem neuesten Release, KB §70.2). Ein arm64-Host, der so
#                                   das amd64-Image bekommt, scheitert dank ARCHITECTURE
#                                   sauber beim Merge statt beim Ausfuehren.
#
# Eigenschaften:
#   - Die Quelle bleibt unangetastet: gebaut wird aus einer Kopie (extension-release je Arch).
#   - extension-release: ID=_any (updatefest, §18.4) + ARCHITECTURE (x86-64 / arm64, §7.4)
#     + SYSEXT_VERSION_ID, wenn [version] angegeben ist (os-release(5)); ein fuehrendes "v"
#     faellt weg. Daran liest der Module Manager die installierte Version ab, auch bei
#     Modulen ohne Health-Route.
#   - squashfs gzip (§18.3: Kernel 6.12 ohne xz/zstd), -all-root, reproduzierbar ueber
#     SOURCE_DATE_EPOCH (Standard: letzter git-Commit, sonst 0).
#   - Vor dem Packen laeuft lint-units.sh; ein ERROR bricht den Build ab.
set -eu
NAME="${1:?name}"; SRC="${2:?rootfs-dir}"; ARCH="${3:?amd64|arm64}"; OUT="${4:?out-dir}"
VERSION="${5:-}"; VERSION="${VERSION#v}"
HERE="$(cd "$(dirname "$0")" && pwd)"

case "$NAME" in *[!a-z0-9_-]*|"") echo "ungueltiger Name: $NAME" >&2; exit 2 ;; esac
case "$VERSION" in *[!0-9A-Za-z.+-]*) echo "ungueltige Version: $VERSION" >&2; exit 2 ;; esac
case "$ARCH" in
  amd64) SYSARCH=x86-64 ;;
  arm64) SYSARCH=arm64 ;;
  *) echo "Architektur $ARCH nicht unterstuetzt (amd64|arm64)" >&2; exit 2 ;;
esac
[ -d "$SRC/usr" ] || { echo "$SRC/usr fehlt - sysext liefert nur /usr (und /opt)" >&2; exit 2; }

if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH=$(git -C "$SRC" log -1 --format=%ct 2>/dev/null || echo 0)
fi
export SOURCE_DATE_EPOCH

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -a "$SRC/." "$STAGE/"
mkdir -p "$STAGE/usr/lib/extension-release.d"
rm -f "$STAGE"/usr/lib/extension-release.d/extension-release.*
printf 'ID=_any\nARCHITECTURE=%s\n' "$SYSARCH" > "$STAGE/usr/lib/extension-release.d/extension-release.$NAME"
[ -z "$VERSION" ] || printf 'SYSEXT_VERSION_ID=%s\n' "$VERSION" >> "$STAGE/usr/lib/extension-release.d/extension-release.$NAME"

sh "$HERE/lint-units.sh" "$STAGE"

umask 022
find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
mkdir -p "$OUT"
RAW="$OUT/$NAME-$ARCH.raw"
rm -f "$RAW" "$RAW.sha256"
# Zeitstempel kommen aus SOURCE_DATE_EPOCH (exportiert); -mkfs-time/-all-time zusaetzlich
# lehnt squashfs-tools 4.6 ab ("can't be used at the same time").
mksquashfs "$STAGE" "$RAW" -all-root -comp gzip -noappend -no-progress -no-xattrs >/dev/null
( cd "$OUT" && sha256sum "$NAME-$ARCH.raw" > "$NAME-$ARCH.raw.sha256" )
if [ "$ARCH" = amd64 ]; then
  cp -f "$RAW" "$OUT/$NAME.raw"
  ( cd "$OUT" && sha256sum "$NAME.raw" > "$NAME.raw.sha256" )
fi
echo "gebaut: $RAW ($(wc -c < "$RAW") Bytes, SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH, ARCHITECTURE=$SYSARCH${VERSION:+, SYSEXT_VERSION_ID=$VERSION})"
