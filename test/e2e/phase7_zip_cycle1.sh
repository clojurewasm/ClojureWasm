#!/usr/bin/env bash
# test/e2e/phase7_zip_cycle1.sh
#
# Phase 7 §9.9 row 7.13 cycle 1 — `clojure.zip` representation +
# constructors + leaf accessors + 4 predicates (D-080 / ADR-0043).

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

# --- Constructors + node accessor ---
got=$("$BIN" -e '(clojure.zip/node (clojure.zip/vector-zip [1 2 3]))' 2>/dev/null)
assert_eq 'vector_zip_node' "$got" '[1 2 3]'

got=$("$BIN" -e '(clojure.zip/node (clojure.zip/seq-zip (quote (1 2 3))))' 2>/dev/null)
assert_eq 'seq_zip_node' "$got" '(1 2 3)'

got=$("$BIN" -e '(clojure.zip/node (clojure.zip/xml-zip {:tag :a :content [1 2]}))' 2>/dev/null)
assert_eq 'xml_zip_node' "$got" '{:tag :a, :content [1 2]}'

# --- branch? / children ---
got=$("$BIN" -e '(clojure.zip/branch? (clojure.zip/vector-zip [1 2 3]))' 2>/dev/null)
assert_eq 'vector_zip_branch' "$got" 'true'

got=$("$BIN" -e '(clojure.zip/children (clojure.zip/vector-zip [1 2 3]))' 2>/dev/null)
assert_eq 'vector_zip_children' "$got" '(1 2 3)'

# --- make-node — rebuild via the stored fn ---
got=$("$BIN" -e '(clojure.zip/make-node (clojure.zip/vector-zip [1 2 3]) :ignored [4 5 6])' 2>/dev/null)
assert_eq 'make_node_vector' "$got" '[4 5 6]'

# --- 4 predicates ---
got=$("$BIN" -e '(clojure.zip/zip-loc? (clojure.zip/vector-zip [1 2 3]))' 2>/dev/null)
assert_eq 'zip_loc_true' "$got" 'true'

got=$("$BIN" -e '(clojure.zip/zip-loc? 42)' 2>/dev/null)
assert_eq 'zip_loc_false' "$got" 'false'

got=$("$BIN" -e '(clojure.zip/vector-zip? (clojure.zip/vector-zip [1 2 3]))' 2>/dev/null)
assert_eq 'vector_zip_pred_true' "$got" 'true'

got=$("$BIN" -e '(clojure.zip/vector-zip? (clojure.zip/seq-zip (quote (1))))' 2>/dev/null)
assert_eq 'vector_zip_pred_false' "$got" 'false'

got=$("$BIN" -e '(clojure.zip/seq-zip? (clojure.zip/seq-zip (quote (1))))' 2>/dev/null)
assert_eq 'seq_zip_pred_true' "$got" 'true'

got=$("$BIN" -e '(clojure.zip/xml-zip? (clojure.zip/xml-zip {:tag :a}))' 2>/dev/null)
assert_eq 'xml_zip_pred_true' "$got" 'true'

# --- instance? dispatch on user TypeDescriptor (row 7.12 cycle 1
#     gap surfaced + fixed by row 7.13 cycle 1) ---
got=$("$BIN" -e '(instance? ZipLoc (clojure.zip/vector-zip [1 2 3]))' 2>/dev/null)
assert_eq 'instance_zip_loc' "$got" 'true'

echo
echo "Phase 7 row 7.13 cycle 1 clojure.zip e2e: all green."
