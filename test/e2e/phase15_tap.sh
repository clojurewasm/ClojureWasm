#!/usr/bin/env bash
# test/e2e/phase15_tap.sh
#
# clojure.core tap system — tap> / add-tap / remove-tap (clj 1.10+, D-502).
# A debugging fan-out: add-tap registers a 1-arg fn; tap> sends a value to
# every registered tap; remove-tap unregisters. cljw delivers asynchronously
# via an agent (send-off, a real worker thread) so tap> is non-blocking and
# returns true, matching clj's contract (clj uses a daemon thread + bounded
# queue; cljw has no java.util.concurrent, so an agent is the no-JVM-faithful
# carrier — D-502). Determinism in the test comes from a promise the tap
# delivers to, deref'd with a timeout (not a sleep).
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# --- the three vars resolve (clojure.core, no require) ---
assert_eq 'resolve' "$("$BIN" -e "(every? some? [(resolve 'tap>) (resolve 'add-tap) (resolve 'remove-tap)])")" 'true'

# --- tap> returns true (non-blocking, room available) ---
assert_eq 'tap_returns_true' "$("$BIN" -e "(tap> 42)")" 'true'

# --- add-tap + tap> delivers the value to the tap ---
out="$("$BIN" - <<'EOF'
(def p (promise))
(def f (fn [x] (deliver p x)))
(add-tap f)
(tap> 99)
(println "delivered:" (deref p 2000 :timeout))
(remove-tap f)
EOF
)"
assert_eq 'delivers' "$out" 'delivered: 99'

# --- remove-tap unregisters: a removed tap is NOT called ---
out="$("$BIN" - <<'EOF'
(def p (promise))
(def f (fn [x] (deliver p x)))
(add-tap f)
(remove-tap f)
(tap> 7)
(println "after-remove:" (deref p 300 :timeout))
EOF
)"
assert_eq 'remove' "$out" 'after-remove: :timeout'

# --- a throwing tap does not break delivery to other taps ---
out="$("$BIN" - <<'EOF'
(def p (promise))
(def bad (fn [_] (throw (ex-info "boom" {}))))
(def good (fn [x] (deliver p x)))
(add-tap bad)
(add-tap good)
(tap> 5)
(println "isolated:" (deref p 2000 :timeout))
(remove-tap bad)
(remove-tap good)
EOF
)"
assert_eq 'fault_isolation' "$out" 'isolated: 5'

echo "ALL phase15_tap PASS"
