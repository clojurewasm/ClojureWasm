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
