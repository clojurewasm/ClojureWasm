#!/usr/bin/env bash
# test/e2e/phase14_system_statics.sh — java.lang.System statics added in the
# Java-class completion campaign: lineSeparator / exit / arraycopy. (currentTime
# Millis / nanoTime / getProperty / getenv are covered by phase15_system_property.)
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# --- lineSeparator (bare + FQCN spelling) ---
# cljw -e prints each form's value pr-quoted, so a bare call prints "\n".
assert_eq 'line_separator' "$("$BIN" -e '(System/lineSeparator)' 2>/dev/null | tail -1)" '"\n"'
assert_eq 'line_separator_fqcn' "$("$BIN" -e '(java.lang.System/lineSeparator)' 2>/dev/null | tail -1)" '"\n"'

# --- arraycopy: copy a[1..4) -> b[0..3) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def a (object-array [1 2 3 4 5]))
(def b (object-array 5))
(System/arraycopy a 1 b 0 3)
(prn (vec b))
EOF
) || fail "arraycopy: non-zero exit ($got)"
assert_eq 'arraycopy' "$(tail -1 <<< "$got")" '[2 3 4 nil nil]'

# --- arraycopy same-array overlap (forward shift) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def a (object-array [1 2 3 4 5]))
(System/arraycopy a 0 a 1 4)
(prn (vec a))
EOF
) || fail "arraycopy_overlap: non-zero exit ($got)"
assert_eq 'arraycopy_overlap' "$(tail -1 <<< "$got")" '[1 1 2 3 4]'

# --- arraycopy out-of-range raises ---
err=$("$BIN" -e '(System/arraycopy (object-array 2) 0 (object-array 2) 0 9)' 2>&1 || true)
case "$err" in *"out of range"*|*"index"*) echo "PASS arraycopy_oob -> raises" ;; *) fail "arraycopy_oob: got '$err'" ;; esac

# --- exit: flushes pending stdout, then exits with (code & 0xFF) ---
# (set +e around the non-zero exit so command-substitution capture survives.)
set +e
out=$("$BIN" - <<'EOF'
(print "before-exit ")
(System/exit 7)
(println "UNREACHABLE")
EOF
); code=$?
"$BIN" -e '(System/exit 256)' >/dev/null 2>&1; wrap=$?
set -e
assert_eq 'exit_code' "$code" '7'
assert_eq 'exit_flushed_stdout' "$out" 'before-exit '
# exit code wraps to the low 8 bits (256 & 0xFF == 0).
assert_eq 'exit_wrap_256' "$wrap" '0'

echo "OK — phase14_system_statics (8 cases) green"
