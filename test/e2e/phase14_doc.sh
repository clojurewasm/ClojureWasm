#!/usr/bin/env bash
# test/e2e/phase14_doc.sh
#
# D-187 part 2: `(doc sym)` prints a Var's documentation (name / arglists /
# docstring) in clojure.repl/doc's format — the user-facing payoff of the
# D-183 Var-metadata surface. `doc` lives in `clojure.repl` (D-513; the
# in-core copy is removed), so non-REPL contexts require it explicitly —
# clj parity: `clj -e '(doc f)'` is unresolved there too, and the REPL
# auto-refer is covered by suites.test-reporters-test. The trailing `nil` is
# `doc`'s (println) return, printed by `cljw -e`.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || { printf 'FAIL %s\n--- got ---\n%s\n--- want ---\n%s\n' "$n" "$g" "$w" >&2; exit 1; }; echo "PASS $n"; }

# defn: name / arglists / docstring. The `(do …)` wrapper keeps the def's
# `#'user/f` return off stdout — only the `doc` output + its nil return show.
got="$("$BIN" -e '(do (require (quote [clojure.repl :refer [doc]])) (defn f "the docstring" [a b] (+ a b)) (doc f))' 2>/dev/null)"
assert_eq 'doc_defn' "$got" '-------------------------
user/f
([a b])
  the docstring
nil'

# defmacro: same shape + the "Macro" marker line (clj-verified: clojure.repl's
# doc prints it for :macro vars; the removed in-core doc did not)
got="$("$BIN" -e '(do (require (quote [clojure.repl :refer [doc]])) (defmacro mm "macro doc" [x] x) (doc mm))' 2>/dev/null)"
assert_eq 'doc_defmacro' "$got" '-------------------------
user/mm
([x])
Macro
  macro doc
nil'

# plain def (no arglists / docstring): just the name
got="$("$BIN" -e '(do (require (quote [clojure.repl :refer [doc]])) (def x 5) (doc x))' 2>/dev/null)"
assert_eq 'doc_plain' "$got" '-------------------------
user/x
nil'

echo "ALL phase14_doc PASS"
