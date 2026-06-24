#!/usr/bin/env bash
# test/e2e/phase14_compiler_specials.sh
#
# clojure.lang.Compiler/specials static field — the set of special-form symbols.
# Real pure-Clojure macro libs read it to know which symbols not to macro-expand:
# org.clojure/tools.macro does `(into #{} (keys clojure.lang.Compiler/specials))`,
# and the libs that ride tools.macro (algo.monads, …) need it. cljw resolves it
# to a map {<special-form-symbol> nil …} whose keys are cljw's ACTUAL special
# forms, derived from the analyzer's SPECIAL_FORMS table so it cannot drift.
# (The map's VALUES are nil — clj's are opaque JVM parser objects; only the keys
# are user-meaningful, and tools.macro reads only the keys.)

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# It is a map, and (keys …) → a usable set (the tools.macro shape). stdin program
# form (not -e) so only explicit `print` output is captured.
got=$("$BIN" - <<'EOF' 2>/dev/null
(print [(map? clojure.lang.Compiler/specials)
        (set? (into #{} (keys clojure.lang.Compiler/specials)))])
EOF
)
assert_eq "specials_map_and_keys_set" "$got" "[true true]"

# Contains the canonical Clojure special forms (a stable subset — cljw may carry
# more, e.g. ns/require/binding, which are analyzer special forms here).
got=$("$BIN" - <<'EOF' 2>/dev/null
(def s (set (map name (keys clojure.lang.Compiler/specials))))
(print (every? s ["if" "def" "let*" "fn*" "do" "quote" "var" "loop*" "recur"
                  "throw" "try" "." "new" "set!"]))
EOF
)
assert_eq "contains_core_special_forms" "$got" "true"

# The tools.macro usage pattern (the exact expression macro.clj:33 evaluates).
got=$("$BIN" - <<'EOF' 2>/dev/null
(print (contains? (into #{} (keys clojure.lang.Compiler/specials)) (quote fn*)))
EOF
)
assert_eq "tools_macro_usage_shape" "$got" "true"

echo "ALL phase14_compiler_specials PASS"
