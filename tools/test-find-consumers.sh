#!/bin/sh
# Tests tools/find-consumers.sh against a stub gh and a throwaway repository with two tags.
#   sh tools/test-find-consumers.sh
set -eu
SRC="$(cd "$(dirname "$0")/.." && pwd)/tools/find-consumers.sh"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# Throwaway lintux-modkit checkout: v0.1.0 and v0.1.1.
R="$W/repo"
mkdir -p "$R/tools"
cp "$SRC" "$R/tools/find-consumers.sh"
git -C "$R" init -q
git -C "$R" -c user.name=t -c user.email=test commit -q --allow-empty -m one
git -C "$R" tag v0.1.0
git -C "$R" -c user.name=t -c user.email=test commit -q --allow-empty -m two
git -C "$R" tag v0.1.1
OLD=$(git -C "$R" rev-parse v0.1.0)
NEW=$(git -C "$R" rev-parse v0.1.1)

# Stub gh: search answers from files, contents from refs/<owner>_<repo>.
mkdir -p "$W/bin" "$W/refs"
printf '%s\n' chicohaager/lintux-modkit foreign/old foreign/noref >"$W/readme"
printf '%s\n' foreign/old own/new >"$W/code-ref"
printf '%s\n' foreign/bogus >"$W/code-gomod"
printf 'v0.1.0 %s\n' "$OLD" | base64 >"$W/refs/foreign_old"
printf 'v0.1.1 %s\n' "$NEW" | base64 >"$W/refs/own_new"
printf 'v0.1.1 %s\n' 0123456789abcdef0123456789abcdef01234567 | base64 >"$W/refs/foreign_bogus"
cat >"$W/bin/gh" <<EOF
#!/bin/sh
W="$W"
case "\$*" in
  *"search/repositories"*) cat "\$W/readme" ;;
  *"filename:lintux-modkit.ref"*) cat "\$W/code-ref" ;;
  *"filename:go.mod"*) cat "\$W/code-gomod" ;;
  *"repos/broken/repo/contents"*) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
  *"/contents/lintux-modkit.ref"*)
    r=\$(printf '%s' "\$2" | sed 's#^repos/##; s#/contents/.*##; s#/#_#')
    if [ -f "\$W/refs/\$r" ]; then cat "\$W/refs/\$r"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  *) echo "stub gh: unexpected \$*" >&2; exit 2 ;;
esac
EOF
chmod +x "$W/bin/gh"

rc=0
PATH="$W/bin:$PATH" sh "$R/tools/find-consumers.sh" >"$W/out" 2>"$W/err" || rc=$?
if [ "$rc" = 0 ]; then pass "rc 0"; else fail "rc $rc"; cat "$W/err"; fi
expect() { if grep -qx "$2" "$W/out"; then pass "$1"; else fail "$1: no line '$2'"; fi; }
expect "old pin is behind the newest tag" "foreign/old v0.1.0 $OLD behind:v0.1.1"
expect "newest pin is current" "own/new v0.1.1 $NEW current"
expect "repository without lintux-modkit.ref" "foreign/noref - - no-ref"
expect "commit unknown to lintux-modkit" "foreign/bogus v0.1.1 0123456789abcdef0123456789abcdef01234567 unknown-commit"
if grep -q '^chicohaager/lintux-modkit ' "$W/out"; then fail "lintux-modkit itself listed"; else pass "lintux-modkit itself left out"; fi
n=$(grep -c '^foreign/old ' "$W/out" || true)
if [ "$n" = 1 ]; then pass "found by two searches, listed once"; else fail "foreign/old listed $n times"; fi
if [ ! -s "$W/err" ]; then pass "nothing on stderr"; else fail "stderr not empty"; cat "$W/err"; fi

# Any other gh failure stops the run instead of counting as no-ref.
printf '%s\n' broken/repo >"$W/code-gomod"
rc=0
PATH="$W/bin:$PATH" sh "$R/tools/find-consumers.sh" >"$W/out" 2>"$W/err" || rc=$?
if [ "$rc" != 0 ]; then pass "HTTP 500 stops the run (rc $rc)"; else fail "HTTP 500 gave rc 0"; fi
if grep -q '^broken/repo ' "$W/out"; then fail "HTTP 500 printed as a result line"; else pass "HTTP 500 not printed as a result"; fi

echo "find-consumers: $fails failure(s)"
[ "$fails" = 0 ]
