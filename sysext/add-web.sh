#!/bin/sh
# Prepare the web part of a module with a dashboard tile inside a sysext root:
#
#   sh add-web.sh <name> <rootfs-dir> <version>
#
#   - copies lintux-modkit's web/common.js and web/styles.css next to the module's own
#     files in <rootfs>/usr/share/casaos/www/modules/<name>/ (one source for every tile),
#   - replaces @VERSION@ in the HTML files (cache-busting: a browser must not keep an
#     old app.js after an upgrade) and turns usr/share/casaos/modules/<name>.json.in
#     into <name>.json,
#   - checks every .js with `node --check` and the module JSON with python3.
set -eu
NAME="${1:?name}"; ROOT="${2:?rootfs-dir}"; VERSION="${3:?version}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
case "$NAME" in *[!a-z0-9_-]*|"") echo "invalid name: $NAME" >&2; exit 2 ;; esac
case "$VERSION" in *[!0-9A-Za-z.+-]*|"") echo "invalid version: $VERSION" >&2; exit 2 ;; esac
WEB="$ROOT/usr/share/casaos/www/modules/$NAME"
JSON_IN="$ROOT/usr/share/casaos/modules/$NAME.json.in"
[ -d "$WEB" ] || { echo "no web directory $WEB" >&2; exit 1; }
[ -f "$JSON_IN" ] || { echo "no module JSON template $JSON_IN" >&2; exit 1; }

cp "$HERE/web/common.js" "$HERE/web/styles.css" "$WEB/"
for f in "$WEB"/*.html; do
  [ -f "$f" ] || continue
  sed -i "s/@VERSION@/$VERSION/g" "$f"
done
sed "s/@VERSION@/$VERSION/g" "$JSON_IN" > "${JSON_IN%.in}"
rm -f "$JSON_IN"

if grep -rl '@VERSION@' "$WEB" "${JSON_IN%.in}" >/dev/null 2>&1; then
  echo "@VERSION@ left in: $(grep -rl '@VERSION@' "$WEB" "${JSON_IN%.in}")" >&2; exit 1
fi
for f in "$WEB"/*.js; do node --check "$f"; done
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["name"]==sys.argv[2], "name"; print("module JSON ok:", d["name"], d.get("version"))' "${JSON_IN%.in}" "$NAME"
