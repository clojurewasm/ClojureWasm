#!/usr/bin/env bash
# test/e2e/phase6_exit_smoke.sh
#
# Phase 6 exit smoke — ROADMAP §9.8 row 6.14.
#
# Asserts the Phase 6 deliverables that are reachable today:
#   - clojure.string / clojure.set / clojure.walk Tier-A surface.
#   - regex (re-find / re-matches).
#   - random-uuid 36-char string format.
#
# The Java-namespaced `(java.util.UUID/randomUUID)` +
# `(.toString (java.util.Date.))` forms from the original 6.14 spec
# require the ___HOST_EXTENSION aggregator to land (currently the
# `runtime/java/<pkg>/<Class>.zig` files declare the marker but no
# code iterates + registers them in `env`). Deferred to D-079;
# 6.14 ships with the available-surface smoke.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

assert_eq() {
    local name="$1"
    local got="$2"
    local want="$3"
    if [[ "$got" != "$want" ]]; then
        fail "$name: got '$got', want '$want'"
    fi
    echo "PASS $name -> $want"
}

# --- clojure.string (Pattern B2 shim + Pattern A defns) ---
assert_eq 'string_upper' "$("$BIN" -e '(clojure.string/upper-case "hi")')" '"HI"'
assert_eq 'string_lower' "$("$BIN" -e '(clojure.string/lower-case "BYE")')" '"bye"'
assert_eq 'string_trim'  "$("$BIN" -e '(clojure.string/trim "  hi  ")')" '"hi"'
assert_eq 'string_capitalize' "$("$BIN" -e '(clojure.string/capitalize "hello world")')" '"Hello world"'
assert_eq 'string_join'  "$("$BIN" -e '(clojure.string/join "," ["a" "b" "c"])')" '"a,b,c"'
assert_eq 'string_blank' "$("$BIN" -e '(clojure.string/blank? "  ")')" 'true'

# --- clojure.set ---
got="$("$BIN" -e '(do (require (quote [clojure.set])) (clojure.set/union #{1 2} #{2 3}))')"
case "$got" in
    "#{1 2 3}"|"#{1 3 2}"|"#{2 1 3}"|"#{2 3 1}"|"#{3 1 2}"|"#{3 2 1}")
        echo "PASS set_union -> $got" ;;
    *) fail "set_union: unexpected '$got'" ;;
esac

# --- clojure.walk (Pattern A defns landed at 6.16.c) ---
assert_eq 'walk_postwalk_inc' "$("$BIN" -e '(clojure.walk/postwalk (fn* [x] (if (integer? x) (inc x) x)) [1 [2 3]])')" '[2 [3 4]]'
got="$("$BIN" -e '(clojure.walk/keywordize-keys {"a" 1})')"
case "$got" in
    "{:a 1}") echo "PASS walk_keywordize -> $got" ;;
    *) fail "walk_keywordize: unexpected '$got'" ;;
esac

# --- regex ---
assert_eq 'regex_find' "$("$BIN" -e '(re-find #"\d+" "abc123")')" '"123"'
assert_eq 'regex_matches' "$("$BIN" -e '(re-matches #"[a-z]+" "hello")')" '"hello"'

# --- random-uuid (substitute for the host-aggregator-gated
# `(java.util.UUID/randomUUID)` form per D-079) ---
# random-uuid now returns a `.uuid` value (ADR-0074); `(str …)` is the bare
# canonical 36-char form (the value itself prints as `#uuid "…"`).
got="$("$BIN" -e '(str (random-uuid))')"
# Pattern: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" (8-4-4-4-12 hex).
if [[ ! "$got" =~ ^\"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\"$ ]]; then
    fail "random_uuid_format: not a 36-char UUID string (got '$got')"
fi
echo "PASS random_uuid_format -> $got"

# --- core glue (sanity for 6.16.a-1..a-3 landings) ---
assert_eq 'core_reduce' "$("$BIN" -e '(reduce + 0 [1 2 3 4 5])')" '15'
assert_eq 'core_map_inc' "$("$BIN" -e '(map inc [1 2 3])')" '(2 3 4)'
assert_eq 'core_filter_pos' "$("$BIN" -e '(filter pos? [-1 0 1 2])')" '(1 2)'

# --- (ns ...) + require + alias ---
got="$("$BIN" -e "(ns demo (:refer-clojure)) (require '[clojure.string :as s]) (s/upper-case \"hi\")" | tail -n 1)"
assert_eq 'ns_require_alias' "$got" '"HI"'

echo ""
echo "=== phase6_exit_smoke: all assertions passed ==="
