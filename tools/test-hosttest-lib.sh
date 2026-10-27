#!/bin/sh
# Test of hosttest-lib.sh with stub btrfs/stat/findmnt/systemctl (no root, no btrfs needed; runs in CI).
#   sh tools/test-hosttest-lib.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
N=0; FAILS=0
ok() { N=$((N + 1)); echo "ok   - $1"; }
bad() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "FAIL - $1"; }
mkdir -p "$T/bin"
# stat -c %i: 256 for paths named *subvol* (a btrfs subvolume root), else the real inode
cat > "$T/bin/stat" <<'S'
#!/bin/sh
case "$3" in *subvol*) echo 256 ;; *) /usr/bin/stat "$@" ;; esac
S
cat > "$T/bin/btrfs" <<'S'
#!/bin/sh
echo "btrfs $*" >> "$STUB_LOG"; [ "$1 $2" = "subvolume delete" ] && rm -rf "$3"; exit 0
S
cat > "$T/bin/findmnt" <<'S'
#!/bin/sh
case "$*" in *"$HT_ROOT/vol"*) echo btrfs ;; esac
S
cat > "$T/bin/systemctl" <<'S'
#!/bin/sh
echo "systemctl $*" >> "$STUB_LOG"; exit 0
S
chmod 755 "$T/bin/"*
export PATH="$T/bin:$PATH" HT_ROOT="$T" STUB_LOG="$T/log"

# a test script: registers and creates a subvol, a dir and a file, then does $1
mk() {
  cat > "$T/t.sh" <<S
$2
. "$HERE/hosttest-lib.sh"
ht_init "$T/made.list"
ht_made subvol "$T/hosttest-subvol"; mkdir "$T/hosttest-subvol"
ht_made dir "$T/hosttest-dir"; mkdir "$T/hosttest-dir"
ht_made file "$T/hosttest-file"; : > "$T/hosttest-file"
$1
ht_done
S
}
gone() { [ ! -e "$T/hosttest-subvol" ] && [ ! -e "$T/hosttest-dir" ] && [ ! -e "$T/hosttest-file" ] && [ ! -e "$T/made.list" ]; }
there() { [ -d "$T/hosttest-subvol" ] && [ -d "$T/hosttest-dir" ] && [ -f "$T/hosttest-file" ] && [ -f "$T/made.list" ]; }
reset() { rm -rf "$T/hosttest-"* "$T/made.list" "$T/keepme" "$T/log"; : > "$T/log"; }

reset; mk 'pass "x"' 'set -u'; sh "$T/t.sh" > "$T/out" 2>&1; rc=$?
[ $rc = 0 ] && there && ok "success: objects stay for the tile test (rc 0)" || bad "success (rc=$rc)"
printf '%s\n' ". \"$HERE/hosttest-lib.sh\"" "HT_LIST=\"$T/made.list\"" 'ht_cleanup' > "$T/c.sh"; sh "$T/c.sh" > "$T/out" 2>&1; rc=$?
[ $rc = 0 ] && gone && grep -q "btrfs subvolume delete $T/hosttest-subvol" "$T/log" && ok "cleanup reads the same list, deletes the subvolume with btrfs" || bad "cleanup (rc=$rc): $(cat "$T/out")"

reset; mk 'fail "y"' 'set -u'; sh "$T/t.sh" > "$T/out" 2>&1; rc=$?
[ $rc = 1 ] && gone && ok "a failed check: everything removed, rc 1" || bad "failure (rc=$rc)"

reset; mk 'false; pass "never"' 'set -eu'; sh "$T/t.sh" > "$T/out" 2>&1; rc=$?
[ $rc != 0 ] && gone && grep -q 'did not finish' "$T/out" && ok "set -e stops the test before ht_done (the 27.10.2026 case): removed, rc $rc" || bad "set -e (rc=$rc): $(cat "$T/out")"

reset; mk 'kill -TERM $$; sleep 5; pass "never"' 'set -u'; sh "$T/t.sh" > "$T/out" 2>&1; rc=$?
[ $rc = 130 ] && gone && ok "SIGTERM (lost ssh): removed, rc 130" || bad "signal (rc=$rc): $(cat "$T/out")"

reset; mk "ht_made dir $T/keepme; mkdir $T/keepme; ht_made dir /; ht_made subvol $T/hosttest-notsub; mkdir $T/hosttest-notsub; ht_made unit ../x-hosttest.service; ht_made unit zfw.service; fail z" 'set -u'
sh "$T/t.sh" > "$T/out" 2>&1; rc=$?
if [ -d "$T/keepme" ] && [ -d "$T/hosttest-notsub" ] && [ -f "$T/made.list" ] && [ -e / ] && ! grep -q 'zfw\|x-hosttest' "$T/log" \
   && grep -q "left (not a test directory): $T/keepme" "$T/out" && grep -q 'left (not a test directory): /$' "$T/out" \
   && grep -q "left (not a test subvolume): $T/hosttest-notsub" "$T/out" && grep -q 'left (not a test unit): zfw.service' "$T/out" \
   && grep -q '5 registered object(s) left' "$T/out" && [ ! -e "$T/hosttest-dir" ]; then
  ok "guards: a dir without a test name, /, a non-subvolume, foreign units stay, are named, the list stays"
else bad "guards (rc=$rc): $(cat "$T/out")"; fi

reset; mk 'ht_made unit hosttest-x.timer; pass a' 'set -u'; sh "$T/t.sh" > /dev/null 2>&1; sh "$T/c.sh" > "$T/out" 2>&1
grep -q 'systemctl disable --now hosttest-x.timer' "$T/log" && ok "a test unit is disabled and removed" || bad "unit: $(cat "$T/log")"

reset; mkdir -p "$T/snaps"; mk "ht_made emptydir $T/snaps2; mkdir $T/snaps2; ht_made emptydir $T/snaps2/top; mkdir $T/snaps2/top; ht_made emptydir $T/snaps; : > $T/snaps/userfile; fail e" 'set -u'
sh "$T/t.sh" > "$T/out" 2>&1
if [ ! -e "$T/snaps2" ] && [ -f "$T/snaps/userfile" ] && gone; then ok "emptydir: empty folders removed (nested, newest first), a folder with content stays with its content"
else bad "emptydir: $(cat "$T/out"; ls -R "$T")"; fi
rm -rf "$T/snaps"

reset; mkdir -p "$T/vol"; mk "ht_made scrub $T/vol; ht_made scrub $T/notbtrfs; kill -TERM \$\$; sleep 5" 'set -u'
sh "$T/t.sh" > "$T/out" 2>&1
if grep -qx "btrfs scrub cancel $T/vol" "$T/log" && ! grep -q "notbtrfs" "$T/log" && grep -q "left (not a btrfs mount): scrub $T/notbtrfs" "$T/out"; then
  ok "scrub: killed test cancels its scrub, only on a btrfs mount"
else bad "scrub: $(cat "$T/out" "$T/log")"; fi

# call: the test's own cleanup function runs on abort; a non-name does not run
reset; mk "own() { : > $T/hosttest-own-ran; }; ht_made call own; ht_made call 'bad-name;x'; false; ht_done" 'set -eu'
sh "$T/t.sh" > "$T/out" 2>&1
if [ -f "$T/hosttest-own-ran" ] && grep -q "left (not a function name): call bad-name;x" "$T/out" && [ ! -e "$T/hosttest-dir" ]; then ok "call: own cleanup function runs on abort, a non-name is refused"
else bad "call: $(cat "$T/out")"; fi
rm -f "$T/hosttest-own-ran"

# HT_KEEP=1: a failure keeps everything
reset; mk 'fail k' 'set -u'; HT_KEEP=1 sh "$T/t.sh" > "$T/out" 2>&1; rc=$?
if [ $rc = 1 ] && there && grep -q 'kept (HT_KEEP=1)' "$T/out"; then ok "HT_KEEP=1 keeps the objects after a failure"; else bad "HT_KEEP (rc=$rc): $(cat "$T/out")"; fi

# /etc/systemd is never a dir/file target, even with a test name
cat > "$T/g.sh" <<S
. "$HERE/hosttest-lib.sh"
for p in /etc/systemd/system/x-hosttest.service /etc/hosttest /etc/btrfs-manager/hosttest.list /DATA/AppData/x-hosttest /DATA/AppData/keep; do
  if ht__allowed "\$p"; then echo "yes \$p"; else echo "no \$p"; fi
done
S
got=$(sh "$T/g.sh" | tr '\n' ' ')
want="no /etc/systemd/system/x-hosttest.service no /etc/hosttest yes /etc/btrfs-manager/hosttest.list yes /DATA/AppData/x-hosttest no /DATA/AppData/keep "
[ "$got" = "$want" ] && ok "paths: /etc/systemd and /etc itself refused, /etc/<module> and /DATA with a test name allowed" || bad "paths: $got"

echo; echo "$((N - FAILS)) of $N cases ok"
exit "$FAILS"
