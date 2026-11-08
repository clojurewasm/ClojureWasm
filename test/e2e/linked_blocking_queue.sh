#!/usr/bin/env bash
# test/e2e/linked_blocking_queue.sh
#
# ADR-0029 / ADR-0106 — java.util.concurrent.LinkedBlockingQueue as a bounded
# FIFO over a cljw vector Value plus a head index. The head index is the point:
# vector.subvec is an O(n) eager copy (D-044), so dequeuing by rebuilding would
# make draining quadratic on a thread pool's hottest path. AD-064 pins drainTo.

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

Q='java.util.concurrent.LinkedBlockingQueue'
MS='java.util.concurrent.TimeUnit/MILLISECONDS'

# --- FIFO order, not LIFO ---
assert_eq 'fifo_order' \
  "$(run "(let [q ($Q. 8)] (doseq [x [:a :b :c]] (.offer q x)) [(.poll q) (.poll q) (.poll q) (.poll q)])")" \
  '[:a :b :c nil]'

# --- bounded: offer refuses past capacity, and space returns after a poll ---
assert_eq 'bounded_offer_refuses_when_full' \
  "$(run "(let [q ($Q. 2)] [(.offer q 1) (.offer q 2) (.offer q 3) (.size q)])")" \
  '[true true false 2]'
assert_eq 'space_returns_after_poll' \
  "$(run "(let [q ($Q. 2)] (.offer q 1) (.offer q 2) (.poll q) [(.offer q 3) (.size q) (.poll q) (.poll q)])")" \
  '[true 2 2 3]'

# --- size / remainingCapacity / isEmpty / peek ---
assert_eq 'size_and_remaining' \
  "$(run "(let [q ($Q. 5)] (.offer q :x) [(.size q) (.remainingCapacity q) (.isEmpty q) (.peek q) (.size q)])")" \
  '[1 4 false :x 1]'
assert_eq 'unbounded_remaining_is_int_max' \
  "$(run "(.remainingCapacity ($Q.))")" '2147483647'
assert_eq 'empty_queue' \
  "$(run "(let [q ($Q. 4)] [(.isEmpty q) (.peek q) (.poll q) (.size q)])")" \
  '[true nil nil 0]'

# --- toArray snapshots the live elements, head first; clear empties ---
assert_eq 'toArray_snapshot_and_clear' \
  "$(run "(let [q ($Q. 8)] (doseq [x [1 2 3]] (.offer q x)) (.poll q)
            (let [snap (vec (.toArray q))] (.clear q) [snap (.size q)]))")" \
  '[[2 3] 0]'

# --- remove drops the first equal element; contains sees the live window ---
assert_eq 'remove_by_value' \
  "$(run "(let [q ($Q. 8)] (doseq [x [:a :b :a]] (.offer q x))
            [(.remove q :a) (vec (.toArray q)) (.remove q :zz) (.contains q :b)])")" \
  '[true [:b :a] false true]'

# --- AD-064: drainTo returns the drained elements and empties the queue ---
assert_eq 'drainTo_returns_and_empties' \
  "$(run "(let [q ($Q. 8)] (doseq [x [1 2 3]] (.offer q x)) [(vec (.drainTo q [])) (.size q)])")" \
  '[[1 2 3] 0]'

# --- the head index survives past the compaction threshold (>32 dequeues) ---
assert_eq 'fifo_survives_compaction' \
  "$(run "(let [q ($Q. 300)]
            (dotimes [i 200] (.offer q i))
            (let [drained (vec (repeatedly 200 #(.poll q)))]
              [(= drained (vec (range 200))) (.size q) (.poll q)]))")" \
  '[true 0 nil]'

# --- timed offer on a full queue: succeeds once a consumer makes room ---
assert_eq 'timed_offer_succeeds_after_a_poll' \
  "$(run "(let [q ($Q. 1)
                _ (.offer q :first)
                f (future (Thread/sleep 80) (.poll q))]
            (let [ok (.offer q :second 2000 $MS)] @f [ok (.poll q)]))")" \
  '[true :second]'

# --- timed offer on a queue nobody drains returns false at the deadline ---
assert_eq 'timed_offer_times_out' \
  "$(run "(let [q ($Q. 1)
                _ (.offer q :first)
                t0 (System/currentTimeMillis)
                ok (.offer q :second 60 $MS)
                dt (- (System/currentTimeMillis) t0)]
            [ok (>= dt 55)])")" \
  '[false true]'

# --- take blocks until a producer offers ---
assert_eq 'take_blocks_then_returns' \
  "$(run "(let [q ($Q. 4)
                f (future (Thread/sleep 60) (.offer q :late))]
            (let [x (.take q)] @f [x (.size q)]))")" \
  '[:late 0]'

# --- timed poll on an empty queue returns nil at the deadline ---
assert_eq 'timed_poll_times_out' \
  "$(run "(let [q ($Q. 4) t0 (System/currentTimeMillis)
                x (.poll q 60 $MS)
                dt (- (System/currentTimeMillis) t0)]
            [x (>= dt 55)])")" \
  '[nil true]'

# --- concurrent producers + consumers lose nothing and duplicate nothing ---
assert_eq 'concurrent_producers_and_consumers_conserve_every_element' \
  "$(run "(let [q  ($Q. 64)
                ps (doall (for [p (range 4)]
                            (future (dotimes [i 100] (.put q (+ (* p 100) i))))))
                cs (doall (for [_ (range 4)]
                            (future (loop [acc []]
                                      (if (= 100 (count acc))
                                        acc
                                        (recur (conj acc (.take q))))))))]
            (doseq [p ps] @p)
            (let [got (sort (mapcat deref cs))]
              [(= got (range 400)) (.size q)]))")" \
  '[true 0]'

# --- class identity ---
assert_eq 'class_name' "$(run "(= \"$Q\" (str (class ($Q. 1))))")" 'true'

echo "OK test/e2e/linked_blocking_queue.sh"
