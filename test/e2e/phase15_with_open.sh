#!/usr/bin/env bash
# test/e2e/phase15_with_open.sh — the with-open macro (D-232).
# `(with-open [name init ...] body)` binds each name, runs body in a try, and
# in the finally calls (.close name) on each name in REVERSE order — even when
# the body throws. A recursive .clj macro over let/try/finally/. (clj-faithful;
# macroexpand parity is pinned by corpus with_open). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# A cljw-native closeable: a deftype with a `close` method, logging to an atom.
# Each program ends in a bare value form (cljw -e echoes the final form's value).
RES='(def log (atom [])) (defprotocol PC (close [this])) (deftype R [id] PC (close [this] (swap! log conj id)))'

# close runs in reverse order, after the body
assert_eq 'reverse-order' \
  "$("$BIN" -e "$RES (with-open [a (->R 1) b (->R 2)] (swap! log conj :body)) @log" 2>&1 | tail -1)" \
  '[:body 2 1]'

# close still runs when the body throws (finally semantics); the throw is caught
assert_eq 'close-on-throw' \
  "$("$BIN" -e "$RES (try (with-open [a (->R 1)] (throw (ex-info \"boom\" {}))) (catch Throwable e :caught)) @log" 2>&1 | tail -1)" \
  '[1]'

# empty bindings → body only, no close
assert_eq 'empty-bindings' \
  "$("$BIN" -e '(with-open [] (+ 1 2))' 2>&1 | tail -1)" \
  '3'

# the with-open expression returns the body value
assert_eq 'returns-body' \
  "$("$BIN" -e "$RES (with-open [a (->R 1)] :result)" 2>&1 | tail -1)" \
  ':result'

echo "OK — phase15_with_open (4 cases) green"
