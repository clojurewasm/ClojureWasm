#!/usr/bin/env bash
# test/e2e/phase15_defmulti_defmethod.sh — defmulti docstring/attr-map + empty
# -body defmethod (surfaced by integrant). `(defmulti name "doc" {:attr …}
# dispatch-fn)` used to mistake the docstring for the dispatch fn ("Cannot call
# value of type 'string'"); the docstring/attr-map are now skipped AND attached
# to the Var metadata (clj parity for :doc). `(defmethod m dv [params])` with no
# body now defines a nil-returning method (clj parity). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# defmulti with docstring + attr-map dispatches correctly (was a string-call err)
assert_eq 'defmulti-docstring-dispatch' \
  "$("$BIN" -e '(do (defmulti area "the area" {:arglists (quote ([shape]))} :kind) (defmethod area :square [s] (* (:side s) (:side s))) (area {:kind :square :side 3}))' 2>&1 | tail -1)" \
  '9'

# docstring is attached to the Var metadata (not discarded)
assert_eq 'defmulti-doc-meta' \
  "$("$BIN" -e '(do (defmulti m "the doc" {:x 1} identity) (:doc (meta (var m))))' 2>&1 | tail -1)" \
  '"the doc"'

# explicit attr-map keys are attached too
assert_eq 'defmulti-attr-meta' \
  "$("$BIN" -e '(do (defmulti m "d" {:x 1} identity) (:x (meta (var m))))' 2>&1 | tail -1)" \
  '1'

# empty-body defmethod defines a nil-returning method (clj parity)
assert_eq 'defmethod-empty-body' \
  "$("$BIN" -e '(do (defmulti m identity) (defmethod m :default [_]) (m :anything))' 2>&1 | tail -1)" \
  'nil'

echo "OK — phase15_defmulti_defmethod (4 cases) green"
