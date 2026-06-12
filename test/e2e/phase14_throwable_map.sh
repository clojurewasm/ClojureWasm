#!/usr/bin/env bash
# test/e2e/phase14_throwable_map.sh
#
# D-389: clojure.core/Throwable->map. cljw exceptions are ex-info values
# (ADR-0059: no JVM Throwable/StackTraceElement), so the partial implemented
# now carries the keys cljw CAN compute from the ex-* primitives —
# :cause / :data / :via (each via entry :type/:message/:data). The per-frame
# :trace and per-via :at keys are OMITTED (not emitted empty) pending the
# D-232 cljw frame-shape decision (PROVISIONAL; AD-029 deferred the same
# frame surface). :type is the AD-003 simple class name (ExceptionInfo).
#
# These pins lock: (1) clj-parity on the present keys, and (2) the
# honest-degraded invariant that :trace is ABSENT, never a masking empty
# vector. When D-232 lands the frame shape, the :trace/:at keys are ADDED
# (additive) and the contains?-false asserts flip then.

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

run() { "$BIN" -e "$1" 2>/dev/null | tail -1; }

# --- present keys (clj-parity) ---
assert_eq 'cause'        "$(run '(:cause (Throwable->map (ex-info "e" {:k 1})))')"                 '"e"'
assert_eq 'data'         "$(run '(:data (Throwable->map (ex-info "e" {:k 1})))')"                  '{:k 1}'
assert_eq 'via_type'     "$(run '(:type (first (:via (Throwable->map (ex-info "e" {:k 1})))))')"   'ExceptionInfo'
assert_eq 'via_message'  "$(run '(:message (first (:via (Throwable->map (ex-info "e" {:k 1})))))')" '"e"'
assert_eq 'via_data'     "$(run '(:data (first (:via (Throwable->map (ex-info "e" {:k 1})))))')"   '{:k 1}'
assert_eq 'via_count'    "$(run '(count (:via (Throwable->map (ex-info "e" {:k 1}))))')"           '1'

# --- cause chain (outer→root; :cause is the ROOT message) ---
assert_eq 'chain_cause'  "$(run '(:cause (Throwable->map (ex-info "outer" {:a 1} (ex-info "inner" {:b 2}))))')" '"inner"'
assert_eq 'chain_via_n'  "$(run '(count (:via (Throwable->map (ex-info "outer" {} (ex-info "inner" {})))))')"   '2'

# --- honest-degraded invariant: :trace / :at ABSENT (not empty), pending D-232 ---
assert_eq 'trace_absent' "$(run '(contains? (Throwable->map (ex-info "e" {})) :trace)')"           'false'
assert_eq 'at_absent'    "$(run '(contains? (first (:via (Throwable->map (ex-info "e" {})))) :at)')" 'false'

echo "OK — phase14_throwable_map (10 cases) green"
