#!/usr/bin/env bash
# test/e2e/phase15_import_macro.sh — the standalone (import …) macro (D-232).
# `(import '(pkg Class …))` / `(import 'pkg.Class)` register class simple-names
# in the current ns (reusing the D-235 :import map). Expands to clojure.core/
# import* calls (the runtime registration fn), clj-faithful. cljw had only the
# `(:import …)` ns directive. Surfaced by clojure.test-clojure.evaluation:20.
# Behaviour parity pinned by corpus import_macro. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# prefix-list import, then use the class via static interop
assert_eq 'prefix-list' \
  "$("$BIN" -e '(import (quote (java.lang Integer))) (Integer/parseInt "42")' 2>&1 | tail -1)" \
  '42'

# bare qualified-symbol import
assert_eq 'bare-symbol' \
  "$("$BIN" -e '(import (quote java.lang.Long)) (Long/parseLong "7")' 2>&1 | tail -1)" \
  '7'

# multiple classes in one prefix list
assert_eq 'multi-class' \
  "$("$BIN" -e '(import (quote (java.lang Integer Long))) [(Integer/parseInt "3") (Long/parseLong "4")]' 2>&1 | tail -1)" \
  '[3 4]'

# import* expansion (one registration call per class)
assert_eq 'expands-to-import-star' \
  "$("$BIN" -e '(macroexpand-1 (quote (import (quote (java.lang Boolean Integer)))))' 2>&1 | tail -1)" \
  '(do (import* "java.lang.Boolean") (import* "java.lang.Integer"))'

echo "OK — phase15_import_macro (4 cases) green"
