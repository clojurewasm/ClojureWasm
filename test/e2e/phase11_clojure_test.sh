#!/usr/bin/env bash
# test/e2e/phase11_clojure_test.sh
#
# §9.13 row 11.2 — clojure.test minimum surface smoke.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# --- Case 1: (is true) → true ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.test/is true)
EOF
) || fail "case1: non-zero exit"
assert_eq 'is_true' "$(last_line "$got")" 'true'

# --- Case 2: (is nil) → false ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.test/is nil)
EOF
) || fail "case2: non-zero exit"
assert_eq 'is_nil' "$(last_line "$got")" 'false'

# --- Case 3: (is false) → false ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.test/is false)
EOF
) || fail "case3: non-zero exit"
assert_eq 'is_false' "$(last_line "$got")" 'false'

# --- Case 4: (is (= 1 1)) → true ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.test/is (= 1 1))
EOF
) || fail "case4: non-zero exit"
assert_eq 'is_eq_int' "$(last_line "$got")" 'true'

# --- Case 5: run-tests over two passing fns ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defn t1 [] (clojure.test/is (= 1 1)))
(defn t2 [] (clojure.test/is true))
(clojure.test/run-tests t1 t2)
EOF
) || fail "case5: non-zero exit"
assert_eq 'run_tests_pass' "$(last_line "$got")" '[2 0]'

# --- Case 6: run-tests over mixed pass/fail ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defn pass1 [] (clojure.test/is true))
(defn fail1 [] (clojure.test/is nil))
(clojure.test/run-tests pass1 fail1)
EOF
) || fail "case6: non-zero exit"
assert_eq 'run_tests_mixed' "$(last_line "$got")" '[1 1]'

echo "phase11_clojure_test: 6/6 cases pass"
