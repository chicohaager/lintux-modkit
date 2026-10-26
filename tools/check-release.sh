#!/usr/bin/env bash
# Does a published release come back byte for byte from its tag? Run after every release.
#
#   tools/check-release.sh <module-repo-dir> <tag> <name> [arch]
#   tools/check-release.sh ../zimaos-wireguard-sysext v1.1.1 wireguard
#   ASSET_FILE=dist/wireguard-amd64.raw tools/check-release.sh . HEAD wireguard   # before uploading
#
# Downloads <name>-<arch>.raw of the release <tag> (gh, from the repository's origin), reads
# the lintux-modkit commit stamped in the image (usr/share/doc/<name>/lintux-modkit.txt) and,
# for Tailscale, TAILSCALE_VERSION from its extension-release, checks the tag and that commit
# out side by side in a temp directory (the layout ../lintux-modkit every build expects) and
# builds there. Exit 0 = same bytes; 1 = different bytes or not rebuildable (a +dirty stamp,
# no stamp, no build output); 2 = usage.
# Why: on 2026-10-26 a rebuild from the commit gave other bytes than the image tested on the
# host, because ../lintux-modkit had moved on since; only a build with the stamped commit matched.
set -euo pipefail

[ $# -ge 3 ] || { sed -n '4,6p' "$0" >&2; exit 2; }
REPO=$(cd "$1" && pwd)
TAG=$2
NAME=$3
ARCH=${4:-amd64}
ASSET="$NAME-$ARCH.raw"
MODKIT=$(cd "$(dirname "$0")/.." && pwd)

T=$(mktemp -d)
cleanup() {
  git -C "$REPO" worktree remove --force "$T/repo/$(basename "$REPO")" 2>/dev/null || true
  git -C "$MODKIT" worktree remove --force "$T/repo/lintux-modkit" 2>/dev/null || true
  rm -rf "${T:?}"
}
trap cleanup EXIT

# ASSET_FILE=<image>: check a local image before it is uploaded (TAG may then be any commit)
if [ -n "${ASSET_FILE:-}" ]; then
  cp "$ASSET_FILE" "$T/$ASSET"
else
  gh release download "$TAG" -R "$(git -C "$REPO" remote get-url origin)" -p "$ASSET" -D "$T" >/dev/null
fi
want=$(sha256sum "$T/$ASSET" | cut -d' ' -f1)

# a missing file is an answer here (Tailscale has no stamp), not a failure: no pipefail for these two
stamp=$(set +o pipefail; unsquashfs -cat "$T/$ASSET" "usr/share/doc/$NAME/lintux-modkit.txt" 2>/dev/null | sed -n 's/^lintux-modkit //p')
tsv=$(set +o pipefail; unsquashfs -cat "$T/$ASSET" "usr/lib/extension-release.d/extension-release.$NAME" 2>/dev/null \
  | sed -n 's/^TAILSCALE_VERSION=//p')
case "$stamp" in
  *+dirty) echo "not rebuildable: $ASSET was built from a changed lintux-modkit ($stamp)" >&2; exit 1 ;;
  unbekannt) echo "not rebuildable: $ASSET names no lintux-modkit commit" >&2; exit 1 ;;
esac

mkdir -p "$T/repo"
W="$T/repo/$(basename "$REPO")"
# gh release create makes the tag on GitHub only: fetch it (and refuse one that moved locally)
git -C "$REPO" rev-parse -q --verify "$TAG^{commit}" >/dev/null \
  || git -C "$REPO" fetch -q origin "refs/tags/$TAG:refs/tags/$TAG"
git -C "$REPO" worktree add -q --detach "$W" "$TAG"
# images without a stamp (Tailscale builds without lintux-modkit) get the current lintux-modkit
git -C "$MODKIT" worktree add -q --detach "$T/repo/lintux-modkit" "${stamp:-HEAD}"

cd "$W"
mkdir -p dist
if [ -n "$tsv" ]; then
  TAILSCALE_VERSION="$tsv" ARCH="$ARCH" OUT="$W/dist/$ASSET" bash ./build.sh > "$T/build.log" 2>&1 \
    || { tail -n 20 "$T/build.log" >&2; echo "build failed" >&2; exit 1; }
else
  bash build.sh "$ARCH" > "$T/build.log" 2>&1 || { tail -n 20 "$T/build.log" >&2; echo "build failed" >&2; exit 1; }
fi
out=""
for f in "dist/$ASSET" "$ASSET"; do [ -f "$f" ] && out=$f && break; done
[ -n "$out" ] || { echo "not rebuildable: the build left no $ASSET" >&2; exit 1; }
got=$(sha256sum "$out" | cut -d' ' -f1)
# KEEP=<dir>: keep the rebuilt image and the release asset for a closer look
[ -z "${KEEP:-}" ] || cp "$out" "$KEEP/rebuilt-$ASSET" && [ -z "${KEEP:-}" ] || cp "$T/$ASSET" "$KEEP/release-$ASSET"

if [ "$got" != "$want" ]; then
  echo "differs: release $TAG $ASSET is $want, the rebuild from $TAG${stamp:+ with lintux-modkit $stamp} gives $got" >&2
  # say what differs: the files, or only their metadata (images packed before lintux-modkit 8d03211
  # took the modes of the work tree they were built in, which a fresh checkout does not restore;
  # Tailscale before 41e33cb stamped the build time)
  unsquashfs -q -d "$T/a" "$T/$ASSET" >/dev/null && unsquashfs -q -d "$T/b" "$W/$out" >/dev/null
  if diff -rq "$T/a" "$T/b" >/dev/null; then
    echo "same files; their metadata differs (modes, times):" >&2
    diff <(unsquashfs -lln "$T/$ASSET" | sed 's/squashfs-root//') <(unsquashfs -lln "$W/$out" | sed 's/squashfs-root//') | sed -n 's/^[<>] /  /p' >&2 || true
  else
    echo "files differ:" >&2
    diff -rq "$T/a" "$T/b" | sed "s#$T/[ab]##g; s/^/  /" >&2 || true
  fi
  exit 1
fi
echo "reproduced: $TAG $ASSET $want${stamp:+ (lintux-modkit ${stamp:0:7})}${tsv:+ (Tailscale $tsv)}"
