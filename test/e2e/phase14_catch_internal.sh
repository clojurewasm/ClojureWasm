#!/usr/bin/env bash
# test/e2e/phase14_catch_internal.sh
#
# ADR-0060 — internal runtime errors (error_catalog) are catchable by
# try/catch via a class-name-bearing synthesized ex_info. Class names are
# grounded against real Clojure (clj): (/ 1 0) → ArithmeticException,
# (nth [1] 5) → IndexOutOfBoundsException, etc. A synthesized exception is
# observably NOT an ExceptionInfo (instance? false, ex-data nil).

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
ll() { awk 'END{print}' <<< "$1"; }

# --- Case 1: (catch Exception ...) catches divide-by-zero ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (/ 1 0) (catch Exception e :caught)))
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'catch_exception_div0' "$(ll "$got")" ':caught'

# --- Case 2: catch the specific ArithmeticException ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (/ 1 0) (catch ArithmeticException e :caught)))
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'catch_arithmetic_specific' "$(ll "$got")" ':caught'

# --- Case 3: catch via Throwable + read the message ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (/ 1 0) (catch Throwable e (ex-message e))))
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'catch_throwable_message' "$(ll "$got")" '"Divide by zero"'

# --- Case 4: index-out-of-range → IndexOutOfBoundsException ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (nth [1] 5) (catch IndexOutOfBoundsException e :caught)))
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'catch_index_oob' "$(ll "$got")" ':caught'

# --- Case 5: a synthesized exception is NOT an ExceptionInfo ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (/ 1 0) (catch Throwable e (instance? clojure.lang.ExceptionInfo e))))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'synth_not_exinfo' "$(ll "$got")" 'false'

# --- Case 6: ex-data on a synthesized exception is nil (not {}) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (/ 1 0) (catch Throwable e (ex-data e))))
EOF
) || fail "case6: non-zero exit ($got)"
assert_eq 'synth_exdata_nil' "$(ll "$got")" 'nil'

# --- Case 7: no-match inner re-raises to the outer catch ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try
  (try (/ 1 0) (catch clojure.lang.ExceptionInfo e :inner))
  (catch ArithmeticException e :outer)))
EOF
) || fail "case7: non-zero exit ($got)"
assert_eq 'no_match_reraise' "$(ll "$got")" ':outer'

# --- Case 8: user ex-info still catchable + ex-data intact (regression) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (throw (ex-info "boom" {:a 1})) (catch clojure.lang.ExceptionInfo e (ex-data e))))
EOF
) || fail "case8: non-zero exit ($got)"
assert_eq 'user_exinfo_exdata' "$(ll "$got")" '{:a 1}'

# --- Case 9: finally still runs on a caught internal error ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (/ 1 0) (catch Exception e :c) (finally (println "fin"))))
EOF
) || fail "case9: non-zero exit ($got)"
assert_eq 'finally_runs' "$(ll "$got")" ':c'

# --- Case 10: (ex-cause x) returns the 3-arg ex-info cause, else nil ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (ex-message (ex-cause (ex-info "outer" {} (ex-info "inner" {})))))
EOF
) || fail "case10: non-zero exit ($got)"
assert_eq 'ex_cause_message' "$(ll "$got")" '"inner"'
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (ex-cause (ex-info "no-cause" {})))
EOF
) || fail "case10b: non-zero exit ($got)"
assert_eq 'ex_cause_nil' "$(ll "$got")" 'nil'

# --- Case 11: deref of a non-IDeref value is a CATCHABLE type error, NOT an
#     uncatchable not-implemented signal (clj: (deref 5) → ClassCastException,
#     catchable). Was `feature_not_supported` (uncatchable). D-446 follow-up. ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (deref 5) :no (catch ClassCastException e :caught)))
EOF
) || fail "case11: non-zero exit ($got)"
assert_eq 'deref_nonref_classcast' "$(ll "$got")" ':caught'
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (deref nil) :no (catch Throwable e :caught)))
EOF
) || fail "case11b: non-zero exit ($got)"
assert_eq 'deref_nil_throwable' "$(ll "$got")" ':caught'
# 3-arg timed deref of a non-blocking ref → also catchable CCE (clj parity).
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (deref (atom 1) 100 :to) :no (catch ClassCastException e :caught)))
EOF
) || fail "case11c: non-zero exit ($got)"
assert_eq 'timed_deref_nonblocking_classcast' "$(ll "$got")" ':caught'

# --- Case 12: conversion / ns fns raise CATCHABLE arg-type errors (were
#     uncatchable feature_not_supported). clj classes: symbol→IllegalArgument,
#     realized?/name/the-ns(non-sym)/symbol-2arg→ClassCast, the-ns(missing
#     sym)→Exception. D-446 follow-up sweep. ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (symbol 5) :no (catch IllegalArgumentException e :caught)))
EOF
) || fail "case12a: non-zero exit ($got)"
assert_eq 'symbol_badconv_illegalarg' "$(ll "$got")" ':caught'
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (realized? 5) :no (catch ClassCastException e :caught)))
EOF
) || fail "case12b: non-zero exit ($got)"
assert_eq 'realized_nonpending_classcast' "$(ll "$got")" ':caught'
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (name 5) :no (catch ClassCastException e :caught)))
EOF
) || fail "case12c: non-zero exit ($got)"
assert_eq 'name_nonnamed_classcast' "$(ll "$got")" ':caught'
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn [(try (the-ns 5) :no (catch ClassCastException e :ccast))
      (try (the-ns 'definitely-no-such-ns) :no (catch Throwable e :nofound))])
EOF
) || fail "case12d: non-zero exit ($got)"
assert_eq 'the_ns_split' "$(ll "$got")" '[:ccast :nofound]'

# --- Case 13: subvec out-of-bounds throws a catchable IndexOutOfBoundsException
#     (was an ex-info → ExceptionInfo, the wrong class). clj parity. ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (subvec [1 2] 0 9) :no (catch IndexOutOfBoundsException e :caught)))
EOF
) || fail "case13: non-zero exit ($got)"
assert_eq 'subvec_oob_indexbounds' "$(ll "$got")" ':caught'

echo "OK — phase14_catch_internal (19 cases) green"
