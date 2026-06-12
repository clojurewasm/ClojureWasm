#!/usr/bin/env bash
# test/e2e/phase15_require_runtime_fn.sh — require as a runtime fn (ADR-0085,
# D-232). `(require ns)` on a computed/local symbol, `(apply require specs)`,
# and `[ns :as alias :refer …]` libspecs now work as a function — the require
# special form keeps the quoted-literal compile-time path and falls through to
# the require Var for non-literal args. Surfaced by clojure.test-clojure.
# metadata:34 `(require ns)`. clj-grounded (corpus require_runtime_fn). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# require on a computed (let-bound) symbol, then use the loaded ns
assert_eq 'require-computed' \
  "$("$BIN" -e '(let [n (quote clojure.string)] (require n)) (clojure.string/upper-case "hi")' 2>&1 | tail -1)" \
  '"HI"'

# apply require (non-head position)
assert_eq 'apply-require' \
  "$("$BIN" -e '(apply require [(quote clojure.set)]) (clojure.set/union #{1} #{2})' 2>&1 | tail -1)" \
  '#{1 2}'

# runtime require with an :as alias across top-level forms
assert_eq 'require-as-alias' \
  "$("$BIN" -e '(let [s (quote [clojure.string :as cs])] (require s)) (cs/lower-case "AB")' 2>&1 | tail -1)" \
  '"ab"'

# the quoted-literal compile-time form still works
assert_eq 'literal-still' \
  "$("$BIN" -e "(require '[clojure.string :as s]) (s/upper-case \"ok\")" 2>&1 | tail -1)" \
  '"OK"'

echo "OK — phase15_require_runtime_fn (4 cases) green"
