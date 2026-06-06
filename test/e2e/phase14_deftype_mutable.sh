#!/usr/bin/env bash
# test/e2e/phase14_deftype_mutable.sh
#
# ADR-0104 / D-288 — mutable deftype fields (`^:unsynchronized-mutable` /
# `^:volatile-mutable` + `set!`). A deftype field carrying the mutability hint
# is assignable via `(set! field v)` INSIDE the type's own methods, with reads
# hitting the live slot (read-after-write in one body sees the new value).
# defrecord forbids mutable fields (clj parity). External `(set! (.field obj) v)`
# stays unsupported (clj rejects it too).
#
# Oracle (clj 1.12): in-method `(set! n (inc n))` then `(str n)` reads live
# (1, then 2, 3 across calls); `(defrecord R [^:unsynchronized-mutable n])`
# errors at macro time.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" != "$want" ]]; then
        fail "$name: got '$got', want '$want'"
    fi
    echo "PASS $name -> $want"
}

last_line() {
    awk 'END { print }' <<< "$1"
}

# --- Case 1: defrecord rejects a mutable field (clj parity) ---
if "$BIN" -e "(defrecord R [^:unsynchronized-mutable n])" >/dev/null 2>&1; then
    fail "defrecord_mutable_rejected: expected non-zero exit"
fi
err=$("$BIN" -e "(defrecord R [^:unsynchronized-mutable n])" 2>&1 || true)
case "$err" in
    *"not supported for record fields"*) echo "PASS defrecord_mutable_rejected" ;;
    *) fail "defrecord_mutable_rejected: unexpected message: $err" ;;
esac

# --- Case 2: in-method set! + live read across calls (counter) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (bump [c]))
(deftype Ctr [^:unsynchronized-mutable n] P (bump [this] (set! n (inc n)) n))
(def c (->Ctr 0))
(bump c) (bump c) (bump c)
EOF
) || fail "counter: non-zero exit ($got)"
assert_eq 'mutable_counter_live_across_calls' "$(last_line "$got")" '3'

# --- Case 3: read-after-write in one body sees the new slot value ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (go [c]))
(deftype C [^:unsynchronized-mutable n] P (go [this] (set! n 5) (+ n n)))
(go (->C 0))
EOF
) || fail "raw: non-zero exit ($got)"
assert_eq 'read_after_write_in_one_body' "$(last_line "$got")" '10'

# --- Case 4: immutable + mutable mix; immutable still readable ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (go [c]))
(deftype C [a ^:unsynchronized-mutable n] P (go [this] (set! n (+ a n)) n))
(def c (->C 10 0))
(go c) (go c)
EOF
) || fail "mix: non-zero exit ($got)"
assert_eq 'immutable_and_mutable_mix' "$(last_line "$got")" '20'

# --- Case 5 (AD-018 pin): :volatile-mutable behaves identically ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (go [c]))
(deftype C [^:volatile-mutable n] P (go [this] (set! n (inc n)) n))
(def c (->C 0))
(go c) (go c)
EOF
) || fail "volatile: non-zero exit ($got)"
assert_eq 'volatile_mutable_same_as_unsynchronized' "$(last_line "$got")" '2'

# --- Case 6 (AD-017 pin): ^long hint ignored — a non-long Value may be set ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defprotocol P (go [c]) (peek* [c]))
(deftype C [^:unsynchronized-mutable ^long n] P (go [this] (set! n "hi") n) (peek* [this] n))
(def c (->C 0))
(go c)
EOF
) || fail "longhint: non-zero exit ($got)"
assert_eq 'long_hint_ignored_accepts_non_long' "$(last_line "$got")" '"hi"'

# --- Case 7: external (set! (.field obj) v) stays unsupported (clj parity) ---
if "$BIN" -e "(deftype C [^:unsynchronized-mutable n]) (def c (->C 0)) (set! (.n c) 5)" >/dev/null 2>&1; then
    fail "external_field_set_rejected: expected non-zero exit"
fi
echo "PASS external_field_set_rejected"

# --- Case 8: both backends agree (--compare) ---
got=$("$BIN" --compare - <<'EOF' 2>/dev/null
(defprotocol P (bump [c]))
(deftype Ctr [^:unsynchronized-mutable n] P (bump [this] (set! n (inc n)) n))
(def c (->Ctr 0))
(bump c) (bump c) (bump c)
EOF
) || fail "compare: non-zero exit ($got)"
case "$(last_line "$got")" in
    *"OK 3"*) echo "PASS dual_backend_agree_compare" ;;
    *) fail "dual_backend_agree_compare: got '$(last_line "$got")'" ;;
esac
