#!/usr/bin/env bash
# test/e2e/phase14_instance_deref_family.sh
#
# D-308 / ADR-0116 — `(instance? clojure.lang.IDeref x)` and the deref /
# pending / ref family of clojure.lang interfaces. Two membership paths:
#   1. NATIVE tag membership (an atom IS an IDeref, a delay IS an IPending) —
#      derived from the interface_membership SSOT, oracle-verified vs `clj`.
#   2. user-deftype PROTOCOL SATISFACTION (∪ arm in instanceQPrim): a deftype
#      that extends the cljw IDeref protocol matches `(instance? clojure.lang.IDeref …)`.
# Native membership is PRIMARY (keyword IS IFn natively even though it does
# not extend the IFn protocol); the protocol arm is ADDITIVE for user types.
# This is why the naive instance?→satisfies? rewrite was reverted (D-308).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- Native IDeref membership (clj-grounded) ---
assert_eq 'ideref_atom'     "$("$BIN" -e '(instance? clojure.lang.IDeref (atom 1))' 2>/dev/null)"     'true'
assert_eq 'ideref_delay'    "$("$BIN" -e '(instance? clojure.lang.IDeref (delay 1))' 2>/dev/null)"    'true'
assert_eq 'ideref_volatile' "$("$BIN" -e '(instance? clojure.lang.IDeref (volatile! 1))' 2>/dev/null)" 'true'
assert_eq 'ideref_reduced'  "$("$BIN" -e '(instance? clojure.lang.IDeref (reduced 1))' 2>/dev/null)"  'true'
assert_eq 'ideref_int'      "$("$BIN" -e '(instance? clojure.lang.IDeref 5)' 2>/dev/null)"            'false'
assert_eq 'ideref_vec'      "$("$BIN" -e '(instance? clojure.lang.IDeref [1])' 2>/dev/null)"          'false'

# --- IRef / IReference (the watchable/meta-mutable ref subset) ---
assert_eq 'iref_atom'       "$("$BIN" -e '(instance? clojure.lang.IRef (atom 1))' 2>/dev/null)"       'true'
assert_eq 'iref_delay'      "$("$BIN" -e '(instance? clojure.lang.IRef (delay 1))' 2>/dev/null)"      'false'

# --- IPending (delay / future / promise / lazy-seq) ---
assert_eq 'ipending_delay'  "$("$BIN" -e '(instance? clojure.lang.IPending (delay 1))' 2>/dev/null)"  'true'
assert_eq 'ipending_lazy'   "$("$BIN" -e '(instance? clojure.lang.IPending (map inc [1]))' 2>/dev/null)" 'true'
assert_eq 'ipending_atom'   "$("$BIN" -e '(instance? clojure.lang.IPending (atom 1))' 2>/dev/null)"   'false'

# --- REGRESSION GUARD: native IFn membership must NOT regress (the bug the
#     naive satisfies?-rewrite introduced — a keyword IS IFn natively). ---
assert_eq 'ifn_keyword'     "$("$BIN" -e '(instance? clojure.lang.IFn :kw)' 2>/dev/null)"             'true'
assert_eq 'ifn_vector'      "$("$BIN" -e '(instance? clojure.lang.IFn [1])' 2>/dev/null)"             'true'

# --- ∪ arm: a user deftype extending the IDeref protocol matches. The deftype
#     form itself prints its type name, so take the last line (the instance? result). ---
DEFT='(deftype Box [v] clojure.lang.IDeref (deref [_] v))'
assert_eq 'ideref_user_deftype' "$("$BIN" -e "$DEFT (instance? clojure.lang.IDeref (->Box 7))" 2>/dev/null | tail -1)" 'true'
# and the ∪ arm must NOT spuriously match a non-implementing interface.
assert_eq 'iterable_user_deftype' "$("$BIN" -e "$DEFT (instance? clojure.lang.IDeref (->Box 7)) (instance? java.util.Map (->Box 7))" 2>/dev/null | tail -1)" 'false'

echo "ALL PASS phase14_instance_deref_family"
