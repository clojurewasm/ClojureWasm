#!/usr/bin/env bash
# test/e2e/phase7_zip_cycle4.sh
#
# Phase 7 §9.9 row 7.13 cycle 4 — `clojure.zip` mutation
# (7 vars: replace / edit / insert-child / append-child /
# insert-right / insert-left / remove). D-080 / ADR-0043.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- replace ---
got=$("$BIN" -e '(clojure.zip/root (clojure.zip/replace (clojure.zip/down (clojure.zip/vector-zip [1 2 3])) 99))' 2>/dev/null)
assert_eq 'replace_first_child' "$got" '[99 2 3]'

# --- edit with variadic args ---
got=$("$BIN" -e '(clojure.zip/root (clojure.zip/edit (clojure.zip/down (clojure.zip/vector-zip [1 2 3])) + 10))' 2>/dev/null)
assert_eq 'edit_with_arg' "$got" '[11 2 3]'

got=$("$BIN" -e '(clojure.zip/root (clojure.zip/edit (clojure.zip/down (clojure.zip/vector-zip [1 2 3])) + 10 100))' 2>/dev/null)
assert_eq 'edit_with_two_args' "$got" '[111 2 3]'

# --- insert-child prepends, append-child appends ---
got=$("$BIN" -e '(clojure.zip/root (clojure.zip/insert-child (clojure.zip/vector-zip [1 2 3]) 0))' 2>/dev/null)
assert_eq 'insert_child_prepend' "$got" '[0 1 2 3]'

got=$("$BIN" -e '(clojure.zip/root (clojure.zip/append-child (clojure.zip/vector-zip [1 2 3]) 4))' 2>/dev/null)
assert_eq 'append_child' "$got" '[1 2 3 4]'

# --- insert-right / insert-left ---
got=$("$BIN" -e '(clojure.zip/root (clojure.zip/insert-right (clojure.zip/down (clojure.zip/vector-zip [1 2 3])) 99))' 2>/dev/null)
assert_eq 'insert_right' "$got" '[1 99 2 3]'

got=$("$BIN" -e '(clojure.zip/root (clojure.zip/insert-left (clojure.zip/right (clojure.zip/down (clojure.zip/vector-zip [1 2 3]))) 99))' 2>/dev/null)
assert_eq 'insert_left' "$got" '[1 99 2 3]'

# --- insert-right at root raises ---
# Top-level surfaces the thrown ex-info's message + `exception` label
# (ADR-0055 am2 / D-144), not the old generic "ThrownValue".
diag=$("$BIN" -e '(clojure.zip/insert-right (clojure.zip/vector-zip [1 2 3]) 99)' 2>&1 || true)
case "$diag" in
    *"Exception"*"insert-right at root has no parent"*) echo "PASS insert_right_root_raises -> ex-info message surfaced" ;;
    *) fail "insert_right_root_raises: missing ex-info message ($diag)" ;;
esac

# --- remove ---
got=$("$BIN" -e '(clojure.zip/root (clojure.zip/remove (clojure.zip/down (clojure.zip/vector-zip [1 2 3]))))' 2>/dev/null)
assert_eq 'remove_first_child' "$got" '[2 3]'

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.zip/root
  (clojure.zip/remove
    (clojure.zip/right
      (clojure.zip/down (clojure.zip/vector-zip [1 2 3]))))))
EOF
)
assert_eq 'remove_middle_child' "$got" '[1 3]'

# --- composition: walk, edit each leaf, return modified root ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (loop* [loc (clojure.zip/vector-zip [1 [2 3] 4])]
  (if (clojure.zip/end? loc)
    (clojure.zip/root loc)
    (let* [n (clojure.zip/node loc)]
      (if (clojure.zip/branch? loc)
        (recur (clojure.zip/next loc))
        (recur (clojure.zip/next (clojure.zip/replace loc (* n 10)))))))))
EOF
)
assert_eq 'walk_and_edit_leaves' "$got" '[10 [20 30] 40]'

echo
echo "Phase 7 row 7.13 cycle 4 mutation e2e: all green."
