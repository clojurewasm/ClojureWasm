#!/usr/bin/env bash
# test/e2e/phase14_prefix_list_libspec.sh — prefix-list libspecs in require/use
# (D-392). clj accepts `[prefix sub-libspec*]` where each sub gets `prefix.`
# prepended: `[clojure [string :as s] [set :as set]]` ≡ requiring clojure.string
# and clojure.set. clj's `libspec?` rule: a vector is a PLAIN libspec iff its
# 2nd element is nil or a keyword; otherwise it is a prefix list. Covers the
# top-level `(require …)` form, the `(ns … (:require …))` arm, and the
# `(ns … (:use … :only …))` arm (potemkin.types uses the last). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# top-level require, single sub-spec
assert_eq 'top-1' \
  "$("$BIN" -e "(require '[clojure [string :as s]]) (s/upper-case \"hi\")" 2>&1 | tail -1)" '"HI"'
# top-level require, multiple sub-specs (string + set)
assert_eq 'top-multi' \
  "$("$BIN" -e "(require '[clojure [string :as s] [set :as set]]) [(s/upper-case \"x\") (set/union #{1} #{2})]" 2>&1 | tail -1)" '["X" #{1 2}]'
# top-level require, bare-symbol sub-spec (no opts)
assert_eq 'top-bare' \
  "$("$BIN" -e "(require '[clojure [string]]) (clojure.string/lower-case \"AB\")" 2>&1 | tail -1)" '"ab"'

# ns :require prefix list
CP="$(mktemp -d)"; trap 'rm -rf "$CP"' EXIT; mkdir -p "$CP/app"
cat > "$CP/app/req.clj" <<'CLJ'
(ns app.req (:require [clojure [string :as s] [set :as set]]))
(defn run [] [(s/trim "  hi ") (set/intersection #{1 2} #{2 3})])
CLJ
assert_eq 'ns-require' \
  "$("$BIN" -cp "$CP" -e '(require (quote app.req)) (app.req/run)' 2>&1 | tail -1)" '["hi" #{2}]'

# ns :use prefix list with :only (potemkin.types shape)
cat > "$CP/app/use.clj" <<'CLJ'
(ns app.use (:use [clojure [set :only (union)]]))
(defn run [] (union #{1} #{2}))
CLJ
assert_eq 'ns-use-only' \
  "$("$BIN" -cp "$CP" -e '(require (quote app.use)) (app.use/run)' 2>&1 | tail -1)" '#{1 2}'

echo "OK — phase14_prefix_list_libspec (5 cases) green"
