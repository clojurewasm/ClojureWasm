#!/usr/bin/env bash
# test/e2e/temporal_hash_eq.sh
#
# Date / Timestamp / java.time values: `=` by value implies equal `hash` (the
# JDK hashCode, AD-009), so hash-set, map get, distinct, frequencies and
# group-by treat two equal allocations as one key. Kanban 20260927170834-6aa890c7.
#
# The per-expression value pins live in test/clj/suites/temporal_hash_eq_test.clj
# and test/diff/clj_corpus/temporal_hash_eq.txt (JVM-grounded). They run on ONE
# backend. THIS file is the dual-backend pin (ADR-0036): each probe goes through
# `cljw --compare`, so tree_walk and vm must agree AND match the JVM value.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
compare() { "$BIN" --compare -e "$1" 2>&1 | tail -1; }

# One probe per value type: [= hash hash-set-count get distinct-count
# frequencies-vals group-by-count] over two equal, separately allocated values.
PROBE='(fn [a b] [(= a b) (hash a) (count (hash-set a b)) (get {a :v} b) (count (distinct [a b])) (vals (frequencies [a b])) (count (group-by identity [a b]))])'

assert_eq 'equal_values_one_key' \
  "$(compare "(let [p $PROBE] [(p (java.util.Date. 5) (java.util.Date. 5)) (p (java.time.Instant/ofEpochSecond 5) (java.time.Instant/ofEpochSecond 5)) (p (java.time.Duration/ofSeconds 5) (java.time.Duration/ofMillis 5000)) (p (java.time.LocalDate/of 2020 3 1) (java.time.LocalDate/of 2020 3 1)) (p (java.time.LocalDateTime/of 2020 3 1 10 0) (java.time.LocalDateTime/of 2020 3 1 10 0)) (p (java.time.LocalTime/of 10 0) (java.time.LocalTime/of 10 0))])")" \
  'OK [[true 5 1 :v 1 (2) 1] [true 5 1 :v 1 (2) 1] [true 5 1 :v 1 (2) 1] [true 4137153 1 :v 1 (2) 1] [true -418824068 1 :v 1 (2) 1] [true -415866691 1 :v 1 (2) 1]]'

assert_eq 'timestamp_one_key' \
  "$(compare "(do (require 'clojure.instant) (let [p $PROBE r clojure.instant/read-instant-timestamp] (p (r \"1970-01-01T00:00:00.005Z\") (r \"1970-01-01T00:00:00.005Z\"))))")" \
  'OK [true 5 1 :v 1 (2) 1]'

# Equal hashes across types never merge keys: Date 5ms, Instant 5s and
# Duration 5s all hash 5, and a Timestamp hashes like its Date, yet each stays
# its own key. cljw keeps Date and Timestamp apart in BOTH directions. The
# JVM's Date.equals accepts a Timestamp one way only, so clj answers
# (= d t) => true and (get {t :t} d) => :t; this case is the AD-075 pin that
# locks cljw's symmetric false / nil.
assert_eq 'same_hash_distinct_types' \
  "$(compare "(do (require 'clojure.instant) (let [t (clojure.instant/read-instant-timestamp \"1970-01-01T00:00:00.005Z\") d (java.util.Date. 5)] [(count {d :d (java.time.Instant/ofEpochSecond 5) :i (java.time.Duration/ofSeconds 5) :u}) (= (hash t) (hash d)) (= t d) (count (hash-set d t)) (= d t) (get {t :t} d)]))")" \
  'OK [3 true false 2 false nil]'

# Temporal values nested in collection keys, and the hash of such a collection.
assert_eq 'nested_keys_and_hash' \
  "$(compare '[(get {[(java.time.LocalDate/of 2020 3 1)] :v} [(java.time.LocalDate/of 2020 3 1)]) (get {#{(java.util.Date. 5)} :v} #{(java.util.Date. 5)}) (hash [(java.util.Date. 5)]) (hash {(java.time.Duration/ofSeconds 5) 1}) (hash #{(java.time.LocalTime/of 10 0)})]')" \
  'OK [:v :v 528065744 -1706640615 -1554734285]'

# Past the array-map threshold the lookup goes through the HAMT hash path.
assert_eq 'hash_map_scale' \
  "$(compare '[(get (zipmap (map #(java.time.LocalDate/ofEpochDay %) (range 20)) (range 20)) (java.time.LocalDate/ofEpochDay 13)) (get (into {} (map (fn [i] [(java.time.Duration/ofSeconds i) i]) (range 40))) (java.time.Duration/ofMillis 17000)) (count (into #{} (repeatedly 100 #(java.time.LocalDate/of 2020 3 1)))) (count (distinct (map #(java.time.LocalDateTime/of 2020 3 1 10 (mod % 4)) (range 50))))]')" \
  'OK [13 17 1 4]'

echo "=== temporal_hash_eq: Date / java.time hash-eq agrees on both backends and with the JVM ==="
