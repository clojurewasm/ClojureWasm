#!/usr/bin/env bash
# test/e2e/phase14_class_names.sh
#
# ADR-0109 — clj-faithful class names for sorted collections + Var. These tags
# previously printed their RAW @tagName ("sorted_map"/"sorted_set"/"var_ref")
# because fqcnForTag lacked NATIVE_ENTRIES rows; now they print the clj simple
# name (clj `.getSimpleName`: PersistentTreeMap / PersistentTreeSet / Var). The
# names round-trip: `(instance? PersistentTreeMap (sorted-map …))` is true, and
# the interface views (IPersistentMap etc.) are unaffected.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last() { awk 'END { print }' <<< "$1"; }
run() { printf '%s\n' "$1" | "$BIN" - 2>&1; }

# (class x) simple name matches clj's .getSimpleName
assert_eq 'class_sorted_map' "$(last "$(run '(prn (class (sorted-map 1 2)))')")" 'PersistentTreeMap'
assert_eq 'class_sorted_set' "$(last "$(run '(prn (class (sorted-set 1)))')")" 'PersistentTreeSet'
assert_eq 'class_var'        "$(last "$(run '(prn (class (var inc)))')")" 'Var'
# the simple name resolves as a class value and instance? round-trips
assert_eq 'inst_treemap'  "$(last "$(run '(prn (instance? PersistentTreeMap (sorted-map 1 2)))')")" 'true'
assert_eq 'inst_treeset'  "$(last "$(run '(prn (instance? PersistentTreeSet (sorted-set 1)))')")" 'true'
assert_eq 'inst_var'      "$(last "$(run '(prn (instance? Var (var inc)))')")" 'true'
# interface views unaffected (sorted map is still an IPersistentMap)
assert_eq 'sorted_is_map' "$(last "$(run '(prn (instance? IPersistentMap (sorted-map 1 2)))')")" 'true'
# a non-member is false (no over-match)
assert_eq 'treemap_not_vec' "$(last "$(run '(prn (instance? PersistentTreeMap [1 2]))')")" 'false'
