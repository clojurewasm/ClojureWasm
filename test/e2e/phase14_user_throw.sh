#!/usr/bin/env bash
# test/e2e/phase14_user_throw.sh
#
# D-144 (ADR-0055 amendment 2) — structured rendering of an uncaught
# user `(throw ...)`. Before this cycle a user throw rendered a degraded
# EDN event (`:kind :unknown :message "ThrownValue"`, no context) because
# it raises `error.ThrownValue` (payload in `dispatch.last_thrown_exception`)
# rather than a catalog `raise`, so `setErrorFmt` never runs and the
# threadlocal `Info` stays null.
#
# The fix builds a synthetic `Info{ origin = .thrown }` at render time
# from the thrown Value + a throw-time `*error-context*` snapshot, so:
#   - EDN `:kind` is `:exception`, `:message` is the ex-message,
#     `:data` carries ex-data;
#   - `(with-context {...} (throw ...))` carries the context as top-level
#     EDN fields (completing the with-context read-side for user throws);
#   - text format shows the message + `[exception]` label, not "ThrownValue".

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_contains() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == *"$want"* ]] || fail "$name: got '$got', want substring '$want'"
    echo "PASS $name -> contains '$want'"
}
assert_not_contains() {
    local name="$1"; local got="$2"; local nope="$3"
    [[ "$got" != *"$nope"* ]] || fail "$name: unexpected substring '$nope' in '$got'"
    echo "PASS $name -> excludes '$nope'"
}

# --- Case 1: ex-info throw renders real kind + message + data (EDN) ---
out=$(CLJW_ERROR_FORMAT=edn "$BIN" -e '(throw (ex-info "boom" {:type :my/err}))' 2>&1 1>/dev/null || true)
assert_contains 'throw_edn_kind'    "$out" ':kind :exception'
assert_contains 'throw_edn_message' "$out" ':message "boom"'
assert_contains 'throw_edn_data'    "$out" ':data {:type :my/err}'
assert_not_contains 'throw_edn_no_unknown'     "$out" ':kind :unknown'
assert_not_contains 'throw_edn_no_thrownvalue' "$out" 'ThrownValue'

# --- Case 2 (read-side): with-context carries context into a user throw ---
cat > /tmp/cljw_uthrow_2.clj <<'EOF'
(require '[cljw.error :refer [with-context]])
(with-context {:request-id "abc" :trace-id "t1"} (throw (ex-info "boom" {:type :x})))
EOF
out=$(CLJW_ERROR_FORMAT=edn "$BIN" /tmp/cljw_uthrow_2.clj 2>&1 | grep "cljw/error" || true)
assert_contains 'throw_ctx_request_id' "$out" ':request-id "abc"'
assert_contains 'throw_ctx_trace_id'   "$out" ':trace-id "t1"'
assert_contains 'throw_ctx_message'    "$out" ':message "boom"'
assert_contains 'throw_ctx_kind'       "$out" ':kind :exception'

# --- Case 3 (control): no with-context => no context fields leak ---
out=$(CLJW_ERROR_FORMAT=edn "$BIN" -e '(throw (ex-info "boom" {}))' 2>&1 1>/dev/null || true)
assert_not_contains 'throw_control_no_ctx' "$out" ':request-id'

# --- Case 4: text format shows message + exception label, not ThrownValue ---
out=$("$BIN" -e '(throw (ex-info "kaboom" {}))' 2>&1 1>/dev/null || true)
assert_contains 'throw_text_message'   "$out" 'kaboom'
assert_contains 'throw_text_label'     "$out" 'Exception'
assert_not_contains 'throw_text_no_tv' "$out" 'ThrownValue'

# --- Case 5: non-ex-info throw renders the value as the message ---
out=$(CLJW_ERROR_FORMAT=edn "$BIN" -e '(throw 42)' 2>&1 1>/dev/null || true)
assert_contains 'throw_nonexinfo_kind'    "$out" ':kind :exception'
assert_contains 'throw_nonexinfo_message' "$out" ':message "42"'

# --- Case 6: uncaught throw still exits non-zero (exit-code regression) ---
exit_code=0
"$BIN" -e '(throw (ex-info "boom" {}))' >/dev/null 2>&1 || exit_code=$?
[[ "$exit_code" -ne 0 ]] || fail "throw_exit_code: expected non-zero exit"
echo "PASS throw_exit_code -> non-zero exit"

echo
echo "Phase 14 D-144 user-throw structured rendering e2e: all green."
