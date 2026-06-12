#!/usr/bin/env bash
# test/e2e/phase15_use_libspec_filter.sh — `:only` / `:exclude` libspec options
# on `(:use …)` / `require`. `:only (a b)` refers ONLY the listed names
# (whitelist, == :refer [a b]); `:exclude (a b)` refers all publics EXCEPT the
# listed (blacklist over env.referAllWithFilter). clj-grounded: under `:only
# (union)` / `:exclude (intersection)`, `(union …)` works and `intersection`
# stays unresolved. Layer 2 (validation-campaign — real libs + upstream suites
# open with `(:use [clojure.test-helper :only (…)])`).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# :only whitelist — union referred, intersection NOT
assert_eq 'only-refers'   "$("$BIN" -e '(ns a (:use [clojure.set :only (union)])) (union #{1} #{2})' 2>&1 | tail -1)" '#{1 2}'
assert_eq 'only-excludes'  "$("$BIN" -e '(ns a (:use [clojure.set :only (union)])) (resolve (quote intersection))' 2>&1 | tail -1)" 'nil'
# :only accepts a vector too
assert_eq 'only-vector'   "$("$BIN" -e '(ns a (:use [clojure.set :only [union]])) (union #{1} #{3})' 2>&1 | tail -1)" '#{1 3}'

# :exclude blacklist — union referred, intersection NOT
assert_eq 'excl-refers'   "$("$BIN" -e '(ns b (:use [clojure.set :exclude (intersection difference)])) (union #{1} #{2})' 2>&1 | tail -1)" '#{1 2}'
assert_eq 'excl-blocks'   "$("$BIN" -e '(ns b (:use [clojure.set :exclude (intersection)])) (resolve (quote intersection))' 2>&1 | tail -1)" 'nil'

# :only on standalone require (lenient — cljw treats it as :refer whitelist)
assert_eq 'req-only'      "$("$BIN" -e '(require (quote [clojure.string :only (upper-case)])) (upper-case "hi")' 2>&1 | tail -1)" '"HI"'

echo "OK — phase15_use_libspec_filter (6 cases) green"
