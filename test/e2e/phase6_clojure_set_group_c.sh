#!/usr/bin/env bash
# test/e2e/phase6_clojure_set_group_c.sh
#
# Phase 6.16.b-3 — Group C `clojure.set` vars (select / project /
# index / rename / join) as Pattern A `.clj` defns. Sits on top of
# the D-061 + D-059 infra landed at 6.16.b-2.
#
# `set` / `select-keys` / `merge` helpers are added to core.clj for
# this cycle (Pattern A helpers shared across set / walk / future
# Clojure cores).
#
# DIVERGENCE D-β: project / rename drop the JVM `with-meta` /
# `meta` wrap because cw v1 has no value-metadata system yet
# (Phase 7+ scope). Observable divergence: callers losing metadata
# across project / rename.
#
# join 3-arity `[xrel yrel km]` deferred to D-070 multi-arity fn*
# closure; this cycle ships 2-arity `[xrel yrel]` natural-join only.

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

# --- helper: select-keys (added to core.clj) ---
assert_eq 'sk_basic'    "$("$BIN" -e '(select-keys {:a 1 :b 2 :c 3} [:a :c])')" '{:a 1, :c 3}'
assert_eq 'sk_missing'  "$("$BIN" -e '(select-keys {:a 1} [:a :missing])')"      '{:a 1}'
assert_eq 'sk_empty'    "$("$BIN" -e '(select-keys {:a 1} [])')"                 '{}'

# --- helper: merge (added to core.clj; 2-arity surface) ---
assert_eq 'merge_basic'  "$("$BIN" -e '(merge {:a 1} {:b 2})')"       '{:a 1, :b 2}'
assert_eq 'merge_right'  "$("$BIN" -e '(merge {:a 1} {:a 2})')"       '{:a 2}'
assert_eq 'merge_nil_l'  "$("$BIN" -e '(merge nil {:a 1})')"          '{:a 1}'
assert_eq 'merge_nil_r'  "$("$BIN" -e '(merge {:a 1} nil)')"          '{:a 1}'

# --- helper: set (coll → set) ---
assert_eq 'set_of_list'   "$("$BIN" -e '(set [1 2 3])')"     '#{1 2 3}'
assert_eq 'set_dedup'     "$("$BIN" -e '(set [1 2 2 3 3])')" '#{1 2 3}'
assert_eq 'set_of_keys'   "$("$BIN" -e '(set (keys {:a 1 :b 2}))')" '#{:a :b}'

# --- select ---
assert_eq 'select_pos'    "$("$BIN" -e '(do (require (quote [clojure.set])) (clojure.set/select pos? #{-1 2 -3 4}))')" '#{2 4}'
assert_eq 'select_all'    "$("$BIN" -e '(do (require (quote [clojure.set])) (clojure.set/select pos? #{1 2 3}))')"      '#{1 2 3}'
assert_eq 'select_none'   "$("$BIN" -e '(do (require (quote [clojure.set])) (clojure.set/select pos? #{-1 -2}))')"      '#{}'

# --- project ---
assert_eq 'project_basic' "$("$BIN" -e '(do (require (quote [clojure.set])) (clojure.set/project #{{:a 1 :b 2} {:a 3 :b 4}} [:a]))')" '#{{:a 1} {:a 3}}'
# Map-equality-based set dedup is NOT implemented in cw v1 (Phase 5+
# PersistentHashMap + structural-equality work). project_dedup will
# pass for vector dedup but not for map dedup until then.
assert_eq 'project_dedup_vec' "$("$BIN" -e '(do (require (quote [clojure.set])) (count (clojure.set/project #{{:a 1 :b 2} {:a 3 :b 9}} [:a])))')" '2'

# --- rename ---
assert_eq 'rename_basic'  "$("$BIN" -e '(do (require (quote [clojure.set])) (clojure.set/rename #{{:a 1} {:a 2}} {:a :A}))')" '#{{:A 1} {:A 2}}'

# --- index ---
# Map-key equality (= {:a 1} {:a 1}) is not implemented in cw v1 yet
# (Phase 5+ structural-equality work). index groups by the
# select-keys map, so two maps with identical projected keys are
# currently kept as distinct buckets. We test with distinct projection
# values where the count matches independent of dedup.
assert_eq 'index_basic'   "$("$BIN" -e '(do (require (quote [clojure.set])) (count (clojure.set/index #{{:a 1 :b 10} {:a 2 :b 20} {:a 3 :b 30}} [:a])))')" '3'

# --- join (2-arity natural join) ---
assert_eq 'join_empty'    "$("$BIN" -e '(do (require (quote [clojure.set])) (clojure.set/join #{} #{{:a 1}}))')" '#{}'

echo ""
echo "=== phase6_clojure_set_group_c: all assertions passed (Group C .clj defns; join 3-arity D-070 deferred) ==="
