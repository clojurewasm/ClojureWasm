#!/usr/bin/env bash
# test/e2e/phase15_defprotocol_docstring.sh — defprotocol docstrings (D-232).
# clj's defprotocol allows an optional protocol-level docstring after the name
# and an optional docstring after each method's arity vectors. cljw used to
# reject the protocol-level docstring ("method signature must be a list").
# Method docstrings + ^type return hints + multiple arity vectors are tolerated
# (only the method-name symbol is read). Surfaced by upstream protocols/
# examples.clj (which then parks on definterface, a JVM-interface unit). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# protocol docstring + method docstrings, then dispatch through a defrecord
P='(defprotocol G "a greeting protocol" (greet [this] "say hi") (loud [this] "SHOUT")) (defrecord Person [nm] G (greet [this] (str "hi " nm)) (loud [this] (str "HI " nm)))'
assert_eq 'dispatch-with-docstrings' \
  "$("$BIN" -e "$P [(greet (->Person \"ann\")) (loud (->Person \"bob\")) (satisfies? G (->Person \"x\"))]" 2>&1 | tail -1)" \
  '["hi ann" "HI bob" true]'

# ^type return hint + multiple arity vectors on one method (hint/arities ignored)
assert_eq 'hinted-multi-arity' \
  "$("$BIN" -e '(defprotocol P (^String baz [a] [a b] "multi-arity, hinted")) (satisfies? P 1)' 2>&1 | tail -1)" \
  'false'

# marker protocol with only a docstring (no methods): defines cleanly and
# satisfies? on a non-member returns false without error. (Membership for a
# type that *extends* a method-less marker is a separate pre-existing gap,
# tracked in D-232 — orthogonal to the docstring fix.)
assert_eq 'marker-docstring-only' \
  "$("$BIN" -e '(defprotocol M "marker only") (satisfies? M 1)' 2>&1 | tail -1)" \
  'false'

# keyword-value option pairs after the name (e.g. :extend-via-metadata true,
# clj 1.10+) are parsed + skipped before the method sigs, so the protocol
# defines and dispatches normally. (The :extend-via-metadata DISPATCH itself —
# metadata-based extension — is not yet honored, tracked D-314; explicit
# extend works, which is what this exercises.) Surfaced by honeysql.
OPT='(defprotocol Sz :extend-via-metadata true (sz [this] "render")) (defrecord Lit [v] Sz (sz [this] (str "<" v ">")))'
assert_eq 'option-pair-extend-via-metadata' \
  "$("$BIN" -e "$OPT [(sz (->Lit 7)) (satisfies? Sz (->Lit 1))]" 2>&1 | tail -1)" \
  '["<7>" true]'

echo "OK — phase15_defprotocol_docstring (4 cases) green"
