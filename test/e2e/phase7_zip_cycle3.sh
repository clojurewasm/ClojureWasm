#!/usr/bin/env bash
# test/e2e/phase7_zip_cycle3.sh
#
# Phase 7 §9.9 row 7.13 cycle 3 — `clojure.zip` traversal
# (3 vars: next / prev / end?). D-080 / ADR-0043.

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

# --- end? on a fresh root is false ---
got=$("$BIN" -e '(do (require (quote [clojure.zip])) (clojure.zip/end? (clojure.zip/vector-zip [1 2 3])))' 2>/dev/null)
assert_eq 'end_fresh_false' "$got" 'false'

# --- next from root descends to first child ---
got=$("$BIN" -e '(do (require (quote [clojure.zip])) (clojure.zip/node (clojure.zip/next (clojure.zip/vector-zip [1 2 3]))))' 2>/dev/null)
assert_eq 'next_first_child' "$got" '1'

# --- depth-first walk visits [root, leaves...] in order ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.zip])
(prn (loop* [loc (clojure.zip/vector-zip [1 [2 3] 4]) acc []]
  (if (clojure.zip/end? loc)
    acc
    (recur (clojure.zip/next loc) (conj acc (clojure.zip/node loc))))))
EOF
)
assert_eq 'dfs_full_walk' "$got" '[[1 [2 3] 4] 1 [2 3] 2 3 4]'

# --- next past end is a fixed point: returns the same loc ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.zip])
(prn (loop* [loc (clojure.zip/vector-zip [1])]
  (if (clojure.zip/end? loc)
    (clojure.zip/end? (clojure.zip/next loc))
    (recur (clojure.zip/next loc)))))
EOF
)
assert_eq 'next_past_end_fixed' "$got" 'true'

# --- prev steps back to previous DFS position ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.zip])
(prn (clojure.zip/node
  (clojure.zip/prev
    (clojure.zip/right
      (clojure.zip/right
        (clojure.zip/down (clojure.zip/vector-zip [1 [2 3] 4])))))))
EOF
)
assert_eq 'prev_to_rightmost_descendant' "$got" '3'

# --- prev from leftmost sibling goes up to parent ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.zip])
(prn (clojure.zip/node
  (clojure.zip/prev
    (clojure.zip/down (clojure.zip/vector-zip [1 2 3])))))
EOF
)
assert_eq 'prev_to_parent' "$got" '[1 2 3]'

echo
echo "Phase 7 row 7.13 cycle 3 traversal e2e: all green."
