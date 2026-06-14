#!/usr/bin/env bash
# test/e2e/phase14_throwable_map.sh
#
# D-389 (DISCHARGED ADR-0140): clojure.core/Throwable->map. cljw exceptions are
# ex-info values (ADR-0059: no JVM Throwable/StackTraceElement). :cause / :data /
# :via (each :type/:message/:data) come from the ex-* primitives; :type is the
# AD-003 simple class name (ExceptionInfo). The per-frame :trace + per-via :at are
# now FILLED for a CAUGHT exception via (stack-trace e) — cljw-shaped
# {:ns :fn :file :line :column} maps, NOT JVM [class method file line] 4-vectors
# (AD-033). A NEVER-THROWN ex-info has no frames, so :trace/:at stay ABSENT
# (honest-degraded, never a masking empty vector).
#
# These pins lock: (1) clj-parity on the present keys, (2) the honest-degraded
# invariant (:trace/:at absent for a frame-less ex-info), and (3) the new caught
# -exception :trace/:at as cljw-shaped maps.

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

# --- honest-degraded invariant: a NEVER-THROWN ex-info has no frames, so
#     :trace / :at stay ABSENT (not empty). ---
assert_eq 'trace_absent' "$(run '(contains? (Throwable->map (ex-info "e" {})) :trace)')"           'false'
assert_eq 'at_absent'    "$(run '(contains? (first (:via (Throwable->map (ex-info "e" {})))) :at)')" 'false'

# --- ADR-0140: a CAUGHT exception carries frames → :trace + per-via :at are
#     present as cljw-shaped {:ns :fn :file :line :column} maps (NOT JVM 4-vectors). ---
assert_eq 'caught_trace_present' "$(run '(do (defn boom [] (/ 1 0)) (try (boom) (catch Throwable e (contains? (Throwable->map e) :trace))))')" 'true'
assert_eq 'caught_at_present'    "$(run '(do (defn boom [] (/ 1 0)) (try (boom) (catch Throwable e (contains? (first (:via (Throwable->map e))) :at))))')" 'true'
assert_eq 'caught_trace_fn'      "$(run '(do (defn boom [] (/ 1 0)) (try (boom) (catch Throwable e (:fn (first (:trace (Throwable->map e)))))))')" '"boom"'

echo "OK — phase14_throwable_map (13 cases, ADR-0140 :trace/:at) green"
