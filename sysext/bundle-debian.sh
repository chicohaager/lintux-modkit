#!/bin/sh
# shellcheck disable=SC2317,SC2329  # der Teil nach der Marke laeuft im Container, nicht hier
# Fremdprogramme aus Debian samt Bibliotheken in eine sysext-Wurzel legen - fuer Module,
# die Werkzeuge mitbringen, die ZimaOS fehlen (Buildroot-Basis, kein Paketmanager).
#
#   sh bundle-debian.sh <name> <rootfs-dir> <amd64|arm64> "<debian-pakete>" <programm>...
#
#   <programm>  absoluter Pfad im Debian-System, z. B. /usr/bin/strace. Er landet unter
#               demselben Pfad in <rootfs-dir>.
#
# Ergebnis in <rootfs-dir>:
#   usr/bin/...                     die Programme, RPATH $ORIGIN/../lib/<name>
#   usr/lib/<name>/                 ihre Bibliotheken ausser dem glibc-Kern, RPATH $ORIGIN
#   usr/share/doc/<name>/packages.txt   Paket und Version je mitgeliefertem Paket
#   usr/share/doc/<name>/<paket>/copyright  Lizenztexte (GPL verlangt sie beim Weitergeben)
#
# Warum so (gemessen auf ZimaOS 1.8.0, ZIMAOS-KNOWLEDGE §79.6):
#   - eigene Bibliotheken unter usr/lib/<name>/ ueberdecken keine des Hosts;
#   - RPATH statt LD_LIBRARY_PATH: die Variable sickert in Host-Werkzeuge (grep warnte
#     ueber libpcre2) und wird von manchen Startern nicht weitergereicht;
#   - glibc kommt vom Host. Debian trixie hat 2.41, ZimaOS 1.8.0 hat 2.42. Der Bau bricht ab,
#     wenn ein Programm eine glibc-Symbolversion ueber GLIBC_MAX verlangt.
set -eu
NAME="${1:?name}"; OUT="${2:?rootfs-dir}"; ARCH="${3:?amd64|arm64}"; PKGS="${4:?debian-pakete}"
shift 4
[ "$#" -gt 0 ] || { echo "mindestens ein Programm angeben" >&2; exit 2; }
case "$NAME" in *[!a-z0-9_-]*|"") echo "ungueltiger Name: $NAME" >&2; exit 2 ;; esac
case "$ARCH" in amd64|arm64) ;; *) echo "Architektur $ARCH nicht unterstuetzt" >&2; exit 2 ;; esac
for p in "$@"; do case "$p" in /*) ;; *) echo "kein absoluter Pfad: $p" >&2; exit 2 ;; esac; done

# Festgenagelt per Digest (Index-Digest von debian:trixie, gezogen 2026-10-23), damit ein
# spaeterer Bau nicht still eine andere Basis nimmt. Neuer Stand: Digest bewusst anheben.
IMAGE="${DEBIAN_IMAGE:-debian:trixie@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308}"
GLIBC_MAX="${GLIBC_MAX:-2.41}"
# Pakete aus dem Debian-Schnappschuss vom Stand des Images (steht in dessen debian.sources), nicht
# vom laufenden Spiegel: sonst holt ein spaeterer Bau andere Paketversionen und das Abbild weicht ab
# (gemessen 2026-10-23: zwei Bauten am selben Tag gleich, aber apt-get update gegen deb.debian.org).
DEBIAN_SNAPSHOT="${DEBIAN_SNAPSHOT:-20261020T213255Z}"
# Der feste Stand haelt auch Sicherheits-Updates fern (Rueckmeldung 25.10.2026). Darum prueft jeder Bau
# die mitgelieferten Pakete gegen den laufenden Spiegel und bricht ab, wenn dort eines neuer ist:
# DEBIAN_SNAPSHOT anheben. Nur wer bewusst einen alten Stand nachbaut, setzt DEBIAN_SNAPSHOT_ALLOW_OLD=1.
DEBIAN_SNAPSHOT_ALLOW_OLD="${DEBIAN_SNAPSHOT_ALLOW_OLD:-0}"

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
# Das Skript im Container: gleiche Datei, Abschnitt nach der Marke.
INNER=$(sed -n '/^#--- im Container ---$/,$p' "$0")

docker run --rm --platform "linux/$ARCH" \
  -e NAME="$NAME" -e PKGS="$PKGS" -e GLIBC_MAX="$GLIBC_MAX" -e DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT" -e DEBIAN_SNAPSHOT_ALLOW_OLD="$DEBIAN_SNAPSHOT_ALLOW_OLD" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v "$OUT:/out" "$IMAGE" sh -c "$INNER" sh "$@"
exit 0

#--- im Container ---
set -eu
export DEBIAN_FRONTEND=noninteractive
S=/etc/apt/sources.list.d/debian.sources
sed -i -E "s#^URIs: http://deb\.debian\.org/(debian(-security)?)\$#URIs: http://snapshot.debian.org/archive/\\1/$DEBIAN_SNAPSHOT#" "$S"
[ "$(grep -c "^URIs: http://snapshot.debian.org/archive/.*/$DEBIAN_SNAPSHOT\$" "$S")" -eq 2 ] || { echo "Schnappschuss nicht eingetragen: $S" >&2; cat "$S" >&2; exit 1; }
apt-get -o Acquire::Check-Valid-Until=false update -qq >/dev/null
# shellcheck disable=SC2086
apt-get install -y -qq --no-install-recommends binutils patchelf file $PKGS >/dev/null
L=/out/usr/lib/$NAME
D=/out/usr/share/doc/$NAME
mkdir -p "$L" "$D"
SKIP='^(libc|libm|libpthread|libdl|librt|ld-linux-x86-64|ld-linux-aarch64|libresolv|libutil|libmvec)\.so'

deps() { ldd "$1" 2>/dev/null | awk '/=> \//{print $3}'; }
for p in "$@"; do
  [ -f "$p" ] || { echo "nicht im Paket: $p" >&2; exit 1; }
  mkdir -p "/out$(dirname "$p")"
  cp -L "$p" "/out$p"
done
# Abhaengigkeiten bis zum Fixpunkt einsammeln
: > /tmp/seen; : > /tmp/srcs
todo=$(for p in "$@"; do deps "$p"; done | sort -u)
while [ -n "$todo" ]; do
  next=""
  for d in $todo; do
    b=$(basename "$d")
    echo "$b" | grep -qE "$SKIP" && continue
    grep -qx "$b" /tmp/seen && continue
    echo "$b" >> /tmp/seen
    echo "$d" >> /tmp/srcs
    cp -L "$d" "$L/$b"
    next="$next $(deps "$d")"
  done
  # shellcheck disable=SC2086  # gewollt: Wortaufteilung der gesammelten Pfade
  todo=$(printf '%s\n' $next | sort -u)
done

for p in "$@"; do
  file -b "/out$p" | grep -q '^ELF' || continue   # Skripte (wg-quick) brauchen kein RPATH
  patchelf --set-rpath "\$ORIGIN/$(echo "$p" | sed 's|^/||; s|[^/]*/|../|g; s|[^/]*$||')usr/lib/$NAME" "/out$p"
done
# shellcheck disable=SC2016  # $ORIGIN ist fuer den Lader, nicht fuer die Shell
for f in "$L"/*; do [ -f "$f" ] && patchelf --set-rpath '$ORIGIN' "$f"; done

# Hoechste verlangte glibc-Version gegen die Grenze pruefen
max=$(for f in "$L"/* $(for p in "$@"; do echo "/out$p"; done); do objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_2\.[0-9]*'; done | sort -t. -k2 -n -u | tail -n 1)
echo "hoechste glibc-Symbolversion: ${max:-keine}"
if [ -n "$max" ] && [ "${max#GLIBC_2.}" -gt "${GLIBC_MAX#2.}" ]; then
  echo "verlangt $max, Grenze GLIBC_$GLIBC_MAX" >&2; exit 1
fi

# Woher stammt jede Datei? Paket + Version und Lizenztext je Paket
for f in "$@" $(cat /tmp/srcs); do
  dpkg -S "$(readlink -f "$f")" 2>/dev/null | cut -d: -f1 | head -n 1
done | sort -u > /tmp/pkgs
: > "$D/packages.txt"
while read -r pk; do
  [ -n "$pk" ] || continue
  dpkg-query -W -f '${Package} ${Version}\n' "$pk" >> "$D/packages.txt"
  if [ -f "/usr/share/doc/$pk/copyright" ]; then
    mkdir -p "$D/$pk"; cp "/usr/share/doc/$pk/copyright" "$D/$pk/copyright"
  fi
done < /tmp/pkgs
echo "Pakete: $(wc -l < "$D/packages.txt"), Bibliotheken: $(find "$L" -type f | wc -l)"

# Frische: dieselben Pakete gegen den laufenden Spiegel (deb.debian.org) halten.
sed -i -E "s#^URIs: http://snapshot\.debian\.org/archive/(debian(-security)?)/$DEBIAN_SNAPSHOT\$#URIs: http://deb.debian.org/\\1#" "$S"
[ "$(grep -c '^URIs: http://deb.debian.org/' "$S")" -eq 2 ] || { echo "Spiegel nicht eingetragen: $S" >&2; exit 1; }
apt-get update -qq >/dev/null
: > /tmp/behind
while read -r pk ver; do
  cand=$(apt-cache policy "$pk" | awk '/Candidate:/{print $2}')
  if [ -n "$cand" ] && [ "$cand" != "(none)" ] && dpkg --compare-versions "$cand" gt "$ver"; then echo "  $pk $ver -> $cand" >> /tmp/behind; fi
done < "$D/packages.txt"
chown -R "$HOST_UID:$HOST_GID" /out
if [ -s /tmp/behind ]; then
  echo "Debian-Stand $DEBIAN_SNAPSHOT ist veraltet, im Spiegel neuer:" >&2; cat /tmp/behind >&2
  if [ "$DEBIAN_SNAPSHOT_ALLOW_OLD" = 1 ]; then echo "DEBIAN_SNAPSHOT_ALLOW_OLD=1: Bau trotzdem fortgesetzt" >&2; else
    echo "DEBIAN_SNAPSHOT anheben (Sicherheits-Updates), oder DEBIAN_SNAPSHOT_ALLOW_OLD=1 nur fuer den Nachbau eines alten Release" >&2; exit 3; fi
else
  echo "Debian-Stand $DEBIAN_SNAPSHOT aktuell: $(wc -l < "$D/packages.txt") Pakete gegen den Spiegel geprueft, keins neuer"
fi
chown -R "$HOST_UID:$HOST_GID" /out
