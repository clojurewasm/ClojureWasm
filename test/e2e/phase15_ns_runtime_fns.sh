#!/usr/bin/env bash
# test/e2e/phase15_ns_runtime_fns.sh — runtime in-ns/use/refer (ADR-0085 C2,
# D-232). in-ns/use/refer are now clojure.core functions (not only analyzer
# special forms), so they work on computed args / in non-head position —
# `(in-ns (gensym))`, `(apply clojure.core/use …)` — which clojure.test-helper's
# temp-ns / eval-in-temp-ns require. Value-level clj parity is pinned by corpus
# ns_runtime_fns; this covers the gensym / apply / return-value shapes a corpus
# can't (gensym is non-deterministic). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# in-ns on a computed symbol returns the ns; the temp-ns shape round-trips
assert_eq 'temp-ns-shape' \
  "$("$BIN" -e '(def outer (ns-name *ns*)) (def n (binding [*ns* *ns*] (in-ns (gensym)) (apply clojure.core/use [(quote clojure.core)]) (inc 41))) [n (ns-name *ns*) (= outer (ns-name *ns*))]' 2>&1 | tail -1)" \
  '[42 user true]'

# in-ns returns the namespace value (ADR-0083)
assert_eq 'in-ns-returns-ns' \
  "$("$BIN" -e '(binding [*ns* *ns*] (ns-name (in-ns (quote some.tmp))))' 2>&1 | tail -1)" \
  'some.tmp'

# in-ns reachable in non-head position via apply (was unresolved before)
assert_eq 'apply-in-ns' \
  "$("$BIN" -e '(binding [*ns* *ns*] (ns-name (apply in-ns [(quote t2)])))' 2>&1 | tail -1)" \
  't2'

echo "OK — phase15_ns_runtime_fns (3 cases) green"
