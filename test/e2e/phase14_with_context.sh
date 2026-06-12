#!/usr/bin/env bash
# test/e2e/phase14_with_context.sh
#
# Phase 14 §9.16 row 14.13 (3) — cljw.error/with-context (ADR-0055).
# `(with-context {ctx} body...)` binds cljw.error/*error-context* (cw
# v1's first dynamic var, Zig-registered) to (merge current ctx) over
# the body, via the `binding` special form. When a catalog error is
# raised inside the dynamic extent, the renderer snapshots the live
# context and merges its entries as top-level fields of the EDN error
# event.
#
# Multi-form stdin/-e stdout ordering is unreliable (D-096), so the
# value cases use a file. A bare `<file.clj>` runs as a script with no
# result echo (ADR-0117 clj-本家 alignment), so the asserted value is
# printed explicitly via `(prn …)`; the read-side case uses the EDN
# error event on stderr (unambiguous).

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
assert_contains() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == *"$want"* ]] || fail "$name: got '$got', want substring '$want'"
    echo "PASS $name -> contains '$want'"
}

# --- Case 1: with-context binds *error-context* over the body ---
cat > /tmp/cljw_wc_1.clj <<'EOF'
(require '[cljw.error :refer [with-context]])
(prn (with-context {:a 1} cljw.error/*error-context*))
EOF
got=$("$BIN" /tmp/cljw_wc_1.clj 2>/dev/null | tail -1)
assert_eq 'with_context_binds' "$got" '{:a 1}'

# --- Case 2: nested with-context merges (stacks) ---
cat > /tmp/cljw_wc_2.clj <<'EOF'
(require '[cljw.error :refer [with-context]])
(prn (with-context {:a 1} (with-context {:b 2} cljw.error/*error-context*)))
EOF
got=$("$BIN" /tmp/cljw_wc_2.clj 2>/dev/null | tail -1)
assert_eq 'with_context_nested_merge' "$got" '{:a 1, :b 2}'

# --- Case 3: *error-context* restores to {} after the dynamic extent ---
cat > /tmp/cljw_wc_3.clj <<'EOF'
(require '[cljw.error :refer [with-context]])
(with-context {:a 1} 0)
(prn cljw.error/*error-context*)
EOF
got=$("$BIN" /tmp/cljw_wc_3.clj 2>/dev/null | tail -1)
assert_eq 'with_context_restores' "$got" '{}'

# --- Case 4 (read-side): catalog error inside with-context carries the
#     context as top-level EDN fields ---
cat > /tmp/cljw_wc_4.clj <<'EOF'
(require '[cljw.error :refer [with-context]])
(with-context {:request-id "abc" :trace-id "t1"} (/ 1 0))
EOF
# `(/ 1 0)` exits non-zero by design; `|| true` keeps `set -o pipefail`
# from aborting on the intentional failure (the EDN event is on stderr).
got=$(CLJW_ERROR_FORMAT=edn "$BIN" /tmp/cljw_wc_4.clj 2>&1 | grep "cljw/error" || true)
assert_contains 'with_context_edn_request_id' "$got" ':request-id "abc"'
assert_contains 'with_context_edn_trace_id' "$got" ':trace-id "t1"'
assert_contains 'with_context_edn_kind' "$got" ':kind :arithmetic_error'

# --- Case 5 (control): no with-context => no extra fields ---
got=$(CLJW_ERROR_FORMAT=edn "$BIN" -e '(/ 1 0)' 2>&1 | grep "cljw/error" || true)
[[ "$got" != *":request-id"* ]] || fail "control_no_context: leaked :request-id"
echo "PASS control_no_context -> no context fields"

echo
echo "Phase 14 row 14.13 (3) with-context e2e: all green."
