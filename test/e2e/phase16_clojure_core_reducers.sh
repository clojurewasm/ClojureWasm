#!/usr/bin/env bash
# test/e2e/phase16_clojure_core_reducers.sh — clojure.core.reducers (D-513 (1)).
#
# The reducer ops are checked against the `clj` oracle in
# test/diff/clj_corpus/reducers.txt (replayed by `corpus_regression`). What THIS
# file covers is what a corpus line cannot: that the namespace resolves at all
# from a cold process, that `fold` is sequential-but-value-correct (AD-058), and
# that the mutable `foldcat` accumulator behaves like clj's rather than like a
# persistent conj.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

ck() { # ck <name> <expr> <expected>
    local got
    got="$("$BIN" -e "$2" 2>&1 | sed -n 1p)"
    [[ "$got" == "$3" ]] || fail "$1: expected '$3', got '$got'"
    echo "PASS $1 -> $got"
}

# The namespace is LAZY (clj does not auto-load it either), so this also proves
# the require path resolves it rather than something having pre-interned it.
ck require-and-map \
    '(do (require (quote [clojure.core.reducers :as r])) (println (into [] (r/map inc [1 2 3]))))' \
    '[2 3 4]'

# The curried 1-arity form — `defcurried` emits a real second arity, so
# ((r/map inc) coll) must equal (r/map inc coll).
ck curried-arity \
    '(do (require (quote [clojure.core.reducers :as r])) (println (into [] ((r/filter even?) [1 2 3 4]))))' \
    '[2 4]'

# fold is SEQUENTIAL here (AD-058: no ForkJoinPool, ADR-0093) — this pins the
# VALUE contract, which a later parallelisation must not change. A large vector
# so the input is past any plausible cutoff `n`.
ck fold-value-on-a-large-vector \
    '(do (require (quote [clojure.core.reducers :as r])) (println (r/fold + (vec (range 10000)))))' \
    '49995000'

# 4-arity fold with a non-reducef combiner: the arm that CLJS gets wrong by
# dropping combinef entirely (survey DIVERGENCE 4).
ck fold-with-a-distinct-combiner \
    '(do (require (quote [clojure.core.reducers :as r])) (println (r/fold 4 + (fn ([] 0) ([a b] (+ a b))) (vec (range 100)))))' \
    '4950'

# foldcat rides a MUTABLE accumulator (java.util.ArrayList + append!), not
# conj — cw v0 substituted conj and silently changed `append!`'s contract.
ck foldcat-counts \
    '(do (require (quote [clojure.core.reducers :as r])) (println (count (r/foldcat (vec (range 500))))))' \
    '500'

ck append!-returns-the-accumulator \
    '(do (require (quote [clojure.core.reducers :as r])) (let [a (r/cat)] (r/append! a 1) (r/append! a 2) (println (count a))))' \
    '2'

# reduced must terminate the reduction. cljw unwraps `reduced` at the IReduce
# boundary exactly as JVM does at coll-reduce, so mapcat has to re-wrap
# (survey DIVERGENCE 3) — CLJS's body would run to completion here.
ck reduced-terminates-through-mapcat \
    '(do (require (quote [clojure.core.reducers :as r])) (println (reduce (fn [a b] (if (> a 3) (reduced a) (+ a b))) 0 (r/mapcat (fn [x] [x x]) [1 2 3 4]))))' \
    '4'

echo "OK — phase16_clojure_core_reducers (7 cases) green"
