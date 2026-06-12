#!/usr/bin/env bash
# test/e2e/phase14_locale.sh
#
# java.util.Locale/US + /ROOT object-valued static-field singletons + the
# String.toUpperCase/toLowerCase 2-arg Locale overload (ignored — cljw casing is
# locale-independent) + (.sym keyword). All landed for honeysql (ADR-0115).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
run() { "$BIN" -e "$1" 2>/dev/null; }

# Locale singletons resolve as values; identity is stable (cached per Runtime).
assert_eq 'locale_us_str'   "$(run '(str java.util.Locale/US)')"   '"en_US"'
assert_eq 'locale_root_str' "$(run '(str java.util.Locale/ROOT)')" '""'
assert_eq 'locale_identity' "$(run '(identical? java.util.Locale/US java.util.Locale/US)')" 'true'
assert_eq 'locale_instance' "$(run '(instance? java.util.Locale java.util.Locale/US)')" 'true'

# toUpperCase/toLowerCase 2-arg with a Locale (the Locale is ignored).
assert_eq 'upper_locale' "$(run '(.toUpperCase "abc" java.util.Locale/US)')"   '"ABC"'
assert_eq 'lower_locale' "$(run '(.toLowerCase "ABC" java.util.Locale/ROOT)')" '"abc"'
# 1-arg still works
assert_eq 'upper_1arg'   "$(run '(.toUpperCase "abc")')" '"ABC"'

# (.sym keyword) → the underlying Symbol (clojure.lang.Keyword.sym).
assert_eq 'sym_simple' "$(run '(str (.sym :foo))')"  '"foo"'
assert_eq 'sym_qual'   "$(run '(str (.sym :a/b))')"  '"a/b"'
assert_eq 'sym_is_sym' "$(run '(symbol? (.sym :x))')" 'true'
