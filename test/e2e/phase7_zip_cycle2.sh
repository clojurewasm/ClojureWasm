#!/usr/bin/env bash
# test/e2e/phase7_zip_cycle2.sh
#
# Phase 7 §9.9 row 7.13 cycle 2 — `clojure.zip` navigation
# (10 vars: down / up / right / left / root / lefts / rights /
# path / leftmost / rightmost). D-080 / ADR-0043.

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

# --- down + node ---
got=$("$BIN" -e '(do (require (quote [clojure.zip])) (clojure.zip/node (clojure.zip/down (clojure.zip/vector-zip [10 20 30]))))' 2>/dev/null)
assert_eq 'down_node' "$got" '10'

# --- down on a leaf returns nil ---
got=$("$BIN" -e '(do (require (quote [clojure.zip])) (clojure.zip/down (clojure.zip/vector-zip 42)))' 2>/dev/null)
assert_eq 'down_leaf_nil' "$got" 'nil'

# --- right / left ---
got=$("$BIN" -e '(do (require (quote [clojure.zip])) (clojure.zip/node (clojure.zip/right (clojure.zip/down (clojure.zip/vector-zip [10 20 30])))))' 2>/dev/null)
assert_eq 'right_node' "$got" '20'

got=$("$BIN" -e '(do (require (quote [clojure.zip])) (clojure.zip/node (clojure.zip/left (clojure.zip/right (clojure.zip/down (clojure.zip/vector-zip [10 20 30]))))))' 2>/dev/null)
assert_eq 'left_node' "$got" '10'

# --- right at rightmost returns nil ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.zip])
(prn (clojure.zip/right
  (clojure.zip/right
    (clojure.zip/right
      (clojure.zip/down (clojure.zip/vector-zip [1 2 3]))))))
EOF
)
assert_eq 'right_past_end_nil' "$got" 'nil'

# --- up climbs to parent ---
got=$("$BIN" -e '(do (require (quote [clojure.zip])) (clojure.zip/node (clojure.zip/up (clojure.zip/down (clojure.zip/vector-zip [10 20 30])))))' 2>/dev/null)
assert_eq 'up_to_root' "$got" '[10 20 30]'

# --- up at root returns nil ---
got=$("$BIN" -e '(do (require (quote [clojure.zip])) (clojure.zip/up (clojure.zip/vector-zip [10 20 30])))' 2>/dev/null)
assert_eq 'up_at_root_nil' "$got" 'nil'

# --- root returns the root node value ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.zip])
(prn (clojure.zip/root
  (clojure.zip/right
    (clojure.zip/down (clojure.zip/vector-zip [10 20 30])))))
EOF
)
assert_eq 'root_value' "$got" '[10 20 30]'

# --- leftmost / rightmost ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.zip])
(prn (clojure.zip/node
  (clojure.zip/leftmost
    (clojure.zip/right
      (clojure.zip/right
        (clojure.zip/down (clojure.zip/vector-zip [10 20 30])))))))
EOF
)
assert_eq 'leftmost' "$got" '10'

got=$("$BIN" -e '(do (require (quote [clojure.zip])) (clojure.zip/node (clojure.zip/rightmost (clojure.zip/down (clojure.zip/vector-zip [10 20 30])))))' 2>/dev/null)
assert_eq 'rightmost' "$got" '30'

# --- lefts / rights — JVM returns a SEQ, not the raw vector field
# (clojure.zip sweep 2026-06-02: `(lefts …)`→`(10 20)` not `[10 20]`). ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.zip])
(prn (clojure.zip/lefts
  (clojure.zip/right
    (clojure.zip/right
      (clojure.zip/down (clojure.zip/vector-zip [10 20 30 40]))))))
EOF
)
assert_eq 'lefts_field' "$got" '(10 20)'

got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.zip])
(prn (clojure.zip/rights
  (clojure.zip/right
    (clojure.zip/down (clojure.zip/vector-zip [10 20 30 40])))))
EOF
)
assert_eq 'rights_field' "$got" '(30 40)'

# --- path walks parent chain, root-down, excluding current ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.zip])
(prn (clojure.zip/path
  (clojure.zip/down
    (clojure.zip/right
      (clojure.zip/down (clojure.zip/vector-zip [10 [20 30] 40]))))))
EOF
)
assert_eq 'path_chain' "$got" '[[10 [20 30] 40] [20 30]]'

echo
echo "Phase 7 row 7.13 cycle 2 navigation e2e: all green."
