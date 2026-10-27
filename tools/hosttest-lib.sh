# shellcheck shell=sh
# Host-test helper of the Lintux modules (lintux-modkit/tools/hosttest-lib.sh), sourced by a module's
# tools/host-test.sh, which is copied next to it onto the host: counts results and removes what the
# test made when the test fails or is aborted (set -e, a signal, a lost ssh connection). After a run
# without failures the objects stay — a tile test or a reboot test uses them — until
# `host-test.sh cleanup`, which reads the same list. HT_KEEP=1 keeps them after a failure too.
#
#   ht_init <listfile>          start; traps EXIT, INT, TERM, HUP
#   ht_made <kind> <path|unit>  register BEFORE creating: subvol, dir, file, unit, emptydir
#                               (emptydir: a folder the tested code makes, removed with rmdir only)
#                               scrub <mount>: a scrub the test starts, cancelled on cleanup — it runs
#                               on in its own process when the test is killed (measured on a ZimaOS 1.8.0 host, 27.10.2026)
#                               call <function>: the test's own cleanup for what has no kind here
#                               (firewall rules, network namespaces, peer processes)
#   pass <text> / fail <text>   count a result
#   ht_done                     end of the test: keep on success, clean up on failure; exit code
#   ht_cleanup                  remove everything registered (newest first), then the list
#
# Each kind is removed only when it still is that kind: a subvol only with inode 256 (the root of
# a btrfs subvolume), a dir/file only below /DATA, /media, /etc/<module> or /tmp with a test
# name, a unit only named *hosttest*, a call only for a function name. A path that fails its check stays and is named.
# (27.10.2026: a probe script with set -e stopped before its cleanup and left two subvolumes on a test host.)

HT_LIST=""; HT_DONE=0; ok=0; bad=0
pass() { ok=$((ok + 1)); echo "OK   $1"; }
fail() { bad=$((bad + 1)); echo "FAIL $1"; }

ht_init() {
  HT_LIST="$1"
  mkdir -p "$(dirname "$HT_LIST")"
  touch "$HT_LIST"
  trap 'ht__exit' EXIT
  trap 'echo "aborted by a signal"; exit 130' INT TERM HUP
}

ht_made() {
  case "$1" in subvol|dir|file|unit|emptydir|scrub|call) ;; *) echo "ht_made: unknown kind $1" >&2; return 2 ;; esac
  printf '%s %s\n' "$1" "$2" >> "$HT_LIST"
}

ht__testname() {
  case "$1" in *hosttest*|*tiletest*) return 0 ;; esac
  return 1
}

ht__allowed() {
  case "$1" in /DATA/?*/*|/media/?*/*|/etc/?*/?*|/tmp/?*|"${HT_ROOT:-/nonexistent}"/?*) ;; *) return 1 ;; esac
  case "$1" in /etc/systemd/*) return 1 ;; esac   # units go through the unit kind
  case "$1" in *..*) return 1 ;; esac
  ht__testname "$1"
}

ht_cleanup() {
  [ -n "$HT_LIST" ] && [ -f "$HT_LIST" ] || { echo "cleanup: no list $HT_LIST"; return 0; }
  left=0
  # newest first: snapshots before the subvolume they were taken of
  awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }' "$HT_LIST" > "$HT_LIST.rev"
  while IFS=' ' read -r kind obj; do
    case "$kind" in
      subvol)
        [ -e "$obj" ] || continue
        if ht__allowed "$obj" && [ "$(stat -c %i "$obj")" = 256 ]; then
          btrfs subvolume delete "$obj" >/dev/null || { echo "left (delete failed): $obj"; left=$((left + 1)); }
        else echo "left (not a test subvolume): $obj"; left=$((left + 1)); fi ;;
      dir)
        [ -e "$obj" ] || continue
        if ht__allowed "$obj" && [ -d "$obj" ] && [ ! -L "$obj" ]; then rm -rf -- "$obj"
        else echo "left (not a test directory): $obj"; left=$((left + 1)); fi ;;
      file)
        [ -e "$obj" ] || [ -L "$obj" ] || continue
        if ht__allowed "$obj" && [ ! -d "$obj" ]; then rm -f -- "$obj"
        else echo "left (not a test file): $obj"; left=$((left + 1)); fi ;;
      call)
        case "$obj" in ""|*[!a-z0-9_]*) echo "left (not a function name): call $obj"; left=$((left + 1)) ;;
          *) "$obj" || { echo "left (cleanup function failed): $obj"; left=$((left + 1)); } ;; esac ;;
      scrub)
        # only on a btrfs mount point; "not running" is fine
        if [ "$(findmnt -no FSTYPE --mountpoint "$obj" 2>/dev/null | head -n 1)" = btrfs ]; then
          btrfs scrub cancel "$obj" >/dev/null 2>&1 || true
        else echo "left (not a btrfs mount): scrub $obj"; left=$((left + 1)); fi ;;
      emptydir)
        # rmdir cannot remove content, so no name check; a folder that is not empty stays (not counted)
        [ -d "$obj" ] && [ ! -L "$obj" ] && rmdir -- "$obj" 2>/dev/null || true ;;
      unit)
        if ht__testname "$obj" && case "$obj" in */*) false ;; *) true ;; esac; then
          systemctl disable --now "$obj" >/dev/null 2>&1 || true
          [ -e "/etc/systemd/system/$obj" ] && rm -f -- "/etc/systemd/system/$obj"
          systemctl daemon-reload || true
        else echo "left (not a test unit): $obj"; left=$((left + 1)); fi ;;
    esac
  done < "$HT_LIST.rev"
  rm -f -- "$HT_LIST.rev"
  if [ "$left" = 0 ]; then rm -f -- "$HT_LIST"; fi
  echo "cleanup: $left registered object(s) left"
  [ "$left" = 0 ]
}

ht__exit() {
  rc=$?
  trap - EXIT
  if [ "$HT_DONE" != 1 ]; then
    if [ "${HT_KEEP:-}" = 1 ]; then echo "test did not finish (exit $rc): kept (HT_KEEP=1), see $HT_LIST"; exit "$rc"; fi
    echo "test did not finish (exit $rc): cleaning up what it made"
    ht_cleanup || true
    exit "$rc"
  fi
}

ht_done() {
  HT_DONE=1
  echo "ok=$ok bad=$bad"
  if [ "$bad" != 0 ]; then
    if [ "${HT_KEEP:-}" = 1 ]; then echo "failures: kept (HT_KEEP=1), see $HT_LIST"; exit 1; fi
    echo "failures: cleaning up what the test made"
    ht_cleanup || true
    exit 1
  fi
  echo "kept for the next step (tile test, reboot test): $(wc -l < "$HT_LIST") object(s) in $HT_LIST — remove with: host-test.sh cleanup"
  exit 0
}
