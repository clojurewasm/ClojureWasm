#!/usr/bin/env bash
# test/e2e/phase16_fs_jail.sh — deploy-mode FS jail (ADR-0123 / SE-6/7).
# CLJW_FS_ROOT confines slurp/spit to one subtree: a path resolves UNDER the
# root (so jail-relative reads work), and `..`/absolute escapes raise a catchable
# error instead of touching the host FS. With no CLJW_FS_ROOT the jail is off
# (local CLI unchanged). Layer 2 (e2e CLI) per ADR-0021.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

JAIL="$(mktemp -d "${TMPDIR:-/tmp}/cljw_jail.XXXXXX")"
trap 'rm -rf "$JAIL"' EXIT
printf 'secret-inside' > "$JAIL/inside.txt"

# 1. Confined read: a jail-relative path resolves UNDER the root and reads.
got=$(CLJW_FS_ROOT="$JAIL" "$BIN" -e '(slurp "inside.txt")')
[[ "$got" == *secret-inside* ]] || fail "confined slurp: got '$got'"
echo "PASS fsjail-confined-read"

# 2. `..` traversal is a CATCHABLE error, not the host file's contents.
got=$(CLJW_FS_ROOT="$JAIL" "$BIN" -e '(try (slurp "../../../../../etc/hosts") (catch Throwable _ :escaped))')
[[ "$got" == ":escaped" ]] || fail "traversal not rejected: got '$got'"
echo "PASS fsjail-traversal-rejected"

# 3. An absolute path OUTSIDE the jail is rejected.
got=$(CLJW_FS_ROOT="$JAIL" "$BIN" -e '(try (slurp "/etc/hosts") (catch Throwable _ :escaped))')
[[ "$got" == ":escaped" ]] || fail "absolute escape not rejected: got '$got'"
echo "PASS fsjail-absolute-rejected"

# 4. Confined write lands INSIDE the jail.
CLJW_FS_ROOT="$JAIL" "$BIN" -e '(spit "out.txt" "written")' >/dev/null
[[ -f "$JAIL/out.txt" ]] || fail "confined spit did not write inside the jail"
[[ "$(cat "$JAIL/out.txt")" == "written" ]] || fail "confined spit wrote wrong content"
echo "PASS fsjail-confined-write"

# 5. A write that escapes the jail is rejected AND does not touch the host FS.
got=$(CLJW_FS_ROOT="$JAIL" "$BIN" -e '(try (spit "../escape.txt" "x") (catch Throwable _ :escaped))')
[[ "$got" == ":escaped" ]] || fail "spit traversal not rejected: got '$got'"
[[ ! -e "$JAIL/../escape.txt" ]] || { rm -f "$JAIL/../escape.txt"; fail "spit ESCAPED the jail (wrote outside)!"; }
echo "PASS fsjail-write-traversal-rejected"

# 6. With NO jail, an absolute read works (local CLI unaffected).
got=$("$BIN" -e "(slurp \"$JAIL/inside.txt\")")
[[ "$got" == *secret-inside* ]] || fail "jail-off local read broke: got '$got'"
echo "PASS fsjail-off-local-unaffected"

echo "OK — phase16_fs_jail (6 cases) green"
