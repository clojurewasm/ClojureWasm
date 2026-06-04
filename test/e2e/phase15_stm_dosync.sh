#!/usr/bin/env bash
# test/e2e/phase15_stm_dosync.sh
#
# Phase B #5 (STM) step (i) — the single-ref LockingTransaction slice:
# (dosync ...) + (ref-set r v) + (alter r f & args), single thread.
# Multi-ref lock ordering, retry-on-conflict + concurrent serializability,
# commute, and ensure are later increments (#5-ii .. #5-v). The engine is
# `runtime/concurrency/lock_tx.zig`; the surface is `lang/primitive/stm.zig`.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { tail -n 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# ref-set inside a transaction commits the new value.
got=$("$BIN" -e '(let [r (ref 0)] (dosync (ref-set r 42)) @r)' 2>/dev/null | last_line)
assert_eq 'dosync_ref_set' "$got" '42'

# alter applies (f current & args) and commits.
got=$("$BIN" -e '(let [r (ref 0)] (dosync (alter r + 5)) @r)' 2>/dev/null | last_line)
assert_eq 'dosync_alter' "$got" '5'

# A transaction sees its OWN writes across multiple ops on one ref.
got=$("$BIN" -e '(let [r (ref 10)] (dosync (alter r + 1) (alter r * 2)) @r)' 2>/dev/null | last_line)
assert_eq 'dosync_sees_own_writes' "$got" '22'

# ref-set then alter: the alter reads the in-txn ref-set value, not the
# committed one.
got=$("$BIN" -e '(let [r (ref 0)] (dosync (ref-set r 5) (alter r inc)) @r)' 2>/dev/null | last_line)
assert_eq 'dosync_in_txn_read' "$got" '6'

# Nested dosync reuses the outer transaction (one commit).
got=$("$BIN" -e '(let [r (ref 0)] (dosync (alter r inc) (dosync (alter r inc))) @r)' 2>/dev/null | last_line)
assert_eq 'dosync_nested' "$got" '2'

# Multi-ref transaction: writes to two refs commit atomically (#5-ii).
got=$("$BIN" -e '(let [a (ref 1) b (ref 2)] (dosync (ref-set a 10) (ref-set b 20)) [@a @b])' 2>/dev/null | last_line)
assert_eq 'dosync_multi_ref' "$got" '[10 20]'

# commute: order-independent in-transaction update (#5-iv). Single-thread it
# behaves like alter; mixed with alter both commit.
got=$("$BIN" -e '(let [r (ref 0)] (dosync (commute r + 5)) @r)' 2>/dev/null | last_line)
assert_eq 'dosync_commute' "$got" '5'
got=$("$BIN" -e '(let [a (ref 1) b (ref 10)] (dosync (alter a inc) (commute b + 5)) [@a @b])' 2>/dev/null | last_line)
assert_eq 'dosync_alter_plus_commute' "$got" '[2 15]'

# --- Concurrency: serializability under contention (#5-iii, AD-013 pin) ---
# 4 future threads each run 100 (dosync (alter c inc)) on the SAME ref. With
# retry-on-conflict (no barge — AD-013), every increment lands: no lost updates,
# so the counter is exactly 400. Without the read-point conflict check + retry,
# concurrent commits would clobber each other and this would be < 400.
got=$("$BIN" -e '(let [c (ref 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 100] (dosync (alter c inc))))) (range 4))) @c)' 2>/dev/null | last_line)
assert_eq 'dosync_concurrent_serializable' "$got" '400'

# Concurrent MULTI-ref: a bank transfer between two refs from 4 threads. The
# id-ordered lock acquisition (#5-ii) is deadlock-free, and each transaction is
# atomic, so the sum invariant holds: 4×50 transfers of -1/+1 give [-100 200]
# (sum still 100). A lost update or a torn commit would break the invariant.
got=$("$BIN" -e '(let [a (ref 100) b (ref 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 50] (dosync (alter a dec) (alter b inc))))) (range 4))) [@a @b])' 2>/dev/null | last_line)
assert_eq 'dosync_concurrent_multi_ref_transfer' "$got" '[-100 200]'

# Concurrent commute: re-applied against the committed value at commit, so a
# commuted counter serializes WITHOUT retrying under contention — still 400.
got=$("$BIN" -e '(let [c (ref 0)] (run! deref (mapv (fn [_] (future (dotimes [_ 100] (dosync (commute c inc))))) (range 4))) @c)' 2>/dev/null | last_line)
assert_eq 'dosync_concurrent_commute' "$got" '400'

# alter / ref-set outside a transaction is a clean error, not a crash.
diag=$("$BIN" -e '(alter (ref 0) inc)' 2>&1 || true)
case "$diag" in
    *"must be called inside a (dosync"*|*"transaction"*)
        echo "PASS alter_out_of_txn_errors -> diagnostic" ;;
    *)
        fail "alter_out_of_txn_errors: expected a no-transaction diagnostic, got '$diag'" ;;
esac

echo
echo "Phase B #5 STM dosync/ref-set/alter (single-ref) e2e: all green."
