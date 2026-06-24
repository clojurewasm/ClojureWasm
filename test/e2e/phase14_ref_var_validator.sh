#!/usr/bin/env bash
# test/e2e/phase14_ref_var_validator.sh — set-validator! / get-validator on STM
# refs + vars + the (ref v :validator f) ctor (D-533). Mirrors the atom/agent
# precedent (ADR-0081 / D-441): the validator runs before the value is exposed;
# a rejected change throws IllegalStateException "Invalid reference state" and
# leaves the reference unchanged. For a ref the validate happens at COMMIT (clj
# Ref.validate in the LockingTransaction loop) so a rejected dosync aborts whole;
# for a var, alter-var-root validates the proposed root before storing it. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# --- ref: set-validator! / get-validator ---
assert_eq 'ref_get' "$("$BIN" -e '(let [r (ref 1)] (set-validator! r pos?) (fn? (get-validator r)))')" 'true'
# set-validator! validates the CURRENT value immediately (clj ARef.setValidator)
assert_eq 'ref_setbad' "$("$BIN" -e '(try (set-validator! (ref 5) neg?) (catch Throwable _ :rej))')" ':rej'

# --- ref: rejection on dosync ref-set (validate at commit, whole-txn abort) ---
assert_eq 'ref_reject' "$("$BIN" -e '(let [r (ref 1)] (set-validator! r pos?) (try (dosync (ref-set r -1)) (catch Throwable _ :rej)))')" ':rej'
assert_eq 'ref_unchanged' "$("$BIN" -e '(let [r (ref 1)] (set-validator! r pos?) (try (dosync (ref-set r -1)) (catch Throwable _ nil)) @r)')" '1'
assert_eq 'ref_accept' "$("$BIN" -e '(let [r (ref 1)] (set-validator! r pos?) (dosync (ref-set r 5)) @r)')" '5'
# alter is validated too (the alter result is the proposed value)
assert_eq 'ref_alter_reject' "$("$BIN" -e '(let [r (ref 1)] (set-validator! r pos?) (try (dosync (alter r - 10)) (catch Throwable _ :rej)) @r)')" '1'
# only the FINAL in-txn value is validated (clj validates at commit, not per set)
assert_eq 'ref_final_only' "$("$BIN" -e '(let [r (ref 1)] (set-validator! r pos?) (dosync (ref-set r -9) (ref-set r 7)) @r)')" '7'
# clearing the validator re-allows
assert_eq 'ref_clear' "$("$BIN" -e '(let [r (ref 1)] (set-validator! r pos?) (set-validator! r nil) (dosync (ref-set r -3)) @r)')" '-3'

# --- ref ctor: (ref v :validator f) accept + bad-initial throw ---
assert_eq 'ref_ctor_good' "$("$BIN" -e '@(ref 1 :validator pos?)')" '1'
assert_eq 'ref_ctor_bad' "$("$BIN" -e '(try (ref -1 :validator pos?) (catch Throwable _ :rej))')" ':rej'
# ctor :meta is observable via (meta r) — not a silent drop
assert_eq 'ref_ctor_meta' "$("$BIN" -e '(meta (ref 1 :meta {:a 1}))')" '{:a 1}'

# --- var: set-validator! / get-validator ---
assert_eq 'var_get' "$("$BIN" -e '(do (def x 1) (set-validator! (var x) pos?) (fn? (get-validator (var x))))')" 'true'

# --- var: rejection on alter-var-root (root left unchanged) ---
assert_eq 'var_reject' "$("$BIN" -e '(do (def x 1) (set-validator! (var x) pos?) (try (alter-var-root (var x) (constantly -5)) (catch Throwable _ :rej)))')" ':rej'
assert_eq 'var_unchanged' "$("$BIN" -e '(do (def x 1) (set-validator! (var x) pos?) (try (alter-var-root (var x) (constantly -5)) (catch Throwable _ nil)) @(var x))')" '1'
assert_eq 'var_accept' "$("$BIN" -e '(do (def x 1) (set-validator! (var x) pos?) (alter-var-root (var x) (constantly 9)) @(var x))')" '9'

# --- the rejection message matches the atom/agent precedent ---
"$BIN" - <<'EOF' >/tmp/cljw_rvv_msg.txt 2>&1 || true
(def r (ref 1))
(set-validator! r pos?)
(try (dosync (ref-set r -1)) (catch Throwable e (print (.getMessage e))))
EOF
assert_eq 'ref_msg' "$(cat /tmp/cljw_rvv_msg.txt)" 'Invalid reference state'

echo "OK — phase14_ref_var_validator (16 cases) green"
