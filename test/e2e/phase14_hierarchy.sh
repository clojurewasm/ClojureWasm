#!/usr/bin/env bash
# test/e2e/phase14_hierarchy.sh — ad-hoc hierarchies: make-hierarchy /
# derive / underive / isa? / parents / ancestors / descendants over a global
# (atom-backed) hierarchy. DIVERGENCE: cljw has no JVM Class, so the class?
# branches of clojure.core's isa?/parents/ancestors are dropped (keyword /
# symbol / vector tags only); derive is lenient on namespacing. Each `cljw
# -e` is a fresh process, so the global hierarchy resets per case.
#
# Layer 2 (e2e CLI) per ADR-0021.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
# isa? base cases (no hierarchy)
assert_eq 'isa_eq'      "$("$BIN" -e '(isa? 5 5)')"                            'true'
assert_eq 'isa_neq'     "$("$BIN" -e '(isa? 5 6)')"                            'false'
assert_eq 'make_hier'   "$("$BIN" -e '(make-hierarchy)')"                      '{:parents {}, :descendants {}, :ancestors {}}'
# derive + isa? (direct + transitive)
assert_eq 'derive_isa'  "$("$BIN" -e '(do (derive :child :parent) (isa? :child :parent))')" 'true'
assert_eq 'derive_trans' "$("$BIN" -e '(do (derive :dog :animal) (derive :animal :thing) (isa? :dog :thing))')" 'true'
assert_eq 'derive_norel' "$("$BIN" -e '(isa? :cat :dog)')"                     'false'
# queries
assert_eq 'parents'     "$("$BIN" -e '(do (derive :child :parent) (parents :child))')" '#{:parent}'
assert_eq 'ancestors'   "$("$BIN" -e '(do (derive :dog :animal) (derive :animal :thing) (vec (sort (map str (ancestors :dog)))))')" '[":animal" ":thing"]'
assert_eq 'descendants' "$("$BIN" -e '(do (derive :dog :animal) (descendants :animal))')" '#{:dog}'
assert_eq 'no_anc'      "$("$BIN" -e '(ancestors :loner)')"                    'nil'
# vector isa? (elementwise)
assert_eq 'isa_vec'     "$("$BIN" -e '(do (derive :dog :animal) (isa? [:dog :dog] [:animal :animal]))')" 'true'
assert_eq 'isa_vec_no'  "$("$BIN" -e '(do (derive :dog :animal) (isa? [:dog :cat] [:animal :animal]))')" 'false'
# underive removes the relationship
assert_eq 'underive'    "$("$BIN" -e '(do (derive :a :b) (underive :a :b) (isa? :a :b))')" 'false'
assert_eq 'underive_keep' "$("$BIN" -e '(do (derive :a :b) (derive :a :c) (underive :a :b) [(isa? :a :b) (isa? :a :c)])')" '[false true]'
# defmulti dispatch consults the global hierarchy via isa? (D-161). The macro
# threads -global-hierarchy into the MultiFn, so derive (even after defmulti)
# is seen; the method cache invalidates on the hierarchy's snapshot identity.
assert_eq 'mm_derive_dispatch' "$("$BIN" -e '(do (defmulti area :shape) (defmethod area :rect [r] :rect-fn) (derive :square :rect) (area {:shape :square}))')" ':rect-fn'
assert_eq 'mm_cache_invalidate' "$("$BIN" -e '(do (defmulti area :shape) (defmethod area :rect [r] :rect-fn) (defmethod area :default [r] :def-fn) (area {:shape :square}) (derive :square :rect) (area {:shape :square}))')" ':rect-fn'
assert_eq 'mm_transitive' "$("$BIN" -e '(do (defmulti area :shape) (defmethod area :s3 [r] :s3-fn) (derive :square :rect) (derive :rect :s3) (area {:shape :square}))')" ':s3-fn'
assert_eq 'mm_default_no_rel' "$("$BIN" -e '(do (defmulti area :shape) (defmethod area :rect [r] :rect-fn) (defmethod area :default [r] :def-fn) (area {:shape :tri}))')" ':def-fn'
assert_eq 'mm_prefer' "$("$BIN" -e '(do (defmulti area :shape) (defmethod area :rect [r] :r) (defmethod area :round [r] :ro) (derive :square :rect) (derive :square :round) (prefer-method area :rect :round) (area {:shape :square}))')" ':r'
echo "OK — phase14_hierarchy (19 cases) green"
