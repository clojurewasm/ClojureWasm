#!/usr/bin/env bash
# test/e2e/phase14_extend_fn.sh — the base `clojure.core/extend` fn (D-393).
# extend-type / extend-protocol are macros that lower to `(rt/__extend-type! …)`;
# `extend` is the runtime fn they are sugar over: `(extend atype & proto+mmaps)`
# where each mmap is a {:method-kw fn} map. Used directly by libs that build
# impl maps at runtime (clojure.tools.reader reader_types.clj:190). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

run() { "$BIN" - <<EOF 2>&1 | tail -1
$1
EOF
}

# single protocol, single method
assert_eq 'extend-basic' \
  "$(run '(defprotocol P (foo [x])) (deftype T []) (extend T P {:foo (fn [x] :extended)}) (prn (foo (T.)))')" ':extended'
# multiple methods in one mmap
assert_eq 'extend-multi-method' \
  "$(run '(defprotocol P (a [x]) (b [x])) (deftype T []) (extend T P {:a (fn [x] 1) :b (fn [x] 2)}) (prn [(a (T.)) (b (T.))])')" '[1 2]'
# two protocols in one extend call
assert_eq 'extend-multi-proto' \
  "$(run '(defprotocol P (p [x])) (defprotocol Q (q [x])) (deftype T []) (extend T P {:p (fn [x] :p)} Q {:q (fn [x] :q)}) (prn [(p (T.)) (q (T.))])')" '[:p :q]'

echo "OK — phase14_extend_fn green"
