#!/usr/bin/env bash
# test/e2e/phase14_tree_seq.sh — D-134 tree-seq: lazy pre-order DFS of all
# nodes (branch? + children). Recursive .clj def + mapcat (lazy). AOT blob.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_eq 'ts_preorder' "$("$BIN" -e '(vec (tree-seq vector? seq [1 [2 3]]))')" '[[1 [2 3]] 1 [2 3] 2 3]'
assert_eq 'ts_count'    "$("$BIN" -e '(count (tree-seq vector? seq [1 [2 [3 [4]]]]))')" '8'
assert_eq 'ts_leaf'     "$("$BIN" -e '(vec (tree-seq (fn* [x] false) seq 42))')" '[42]'
assert_eq 'ts_root'     "$("$BIN" -e '(first (tree-seq vector? seq [:root :a]))')" '[:root :a]'
assert_eq 'ts_leaves'   "$("$BIN" -e '(vec (filter (complement vector?) (tree-seq vector? seq [1 [2 3] 4])))')" '[1 2 3 4]'
echo "OK — phase14_tree_seq smoke (5 cases) green"
