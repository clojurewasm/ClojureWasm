#!/usr/bin/env bash
# test/e2e/phase8_exit_smoke.sh
#
# §9.10 row 8.7 — Phase 8 exit-criterion smoke. Verifies the
# headline end-to-end paths the Phase 8 Exit criterion enumerates:
#
#   - bench gate active (informational ok; 1.2x ceiling wired per row 8.3)
#   - dual-backend `cljw --compare` end-to-end (row 8.4)
#   - transient surface end-to-end (transient → conj!/assoc!/disj! → persistent!, row 8.5)
#   - D-089 retro-audit slow-paths (12 collection primitives extend-type-able, row 8.6)
#
# Per-feature e2e lives in:
#   - phase8_compare_cli.sh (--compare)
#   - phase8_d089_{seq,lookup,assoc,set}_extend.sh (D-089)
#
# This file is the rolled-up smoke that proves the surfaces compose.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# --- (1) transient round-trip end-to-end (row 8.5) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(persistent! (conj! (conj! (transient []) :a) :b))
EOF
) || fail "(1): non-zero exit ($got)"
assert_eq 'transient_vector_round_trip' "$(last_line "$got")" '[:a :b]'

# --- (2) transient map round-trip (row 8.5 cycle 2) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(persistent! (assoc! (transient {}) :k 42))
EOF
) || fail "(2): non-zero exit ($got)"
assert_eq 'transient_map_round_trip' "$(last_line "$got")" '{:k 42}'

# --- (3) transient set round-trip + map-invert discharge form (row 8.5 cycle 3) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(persistent! (disj! (conj! (transient #{}) :a) :a))
EOF
) || fail "(3): non-zero exit ($got)"
assert_eq 'transient_set_round_trip' "$(last_line "$got")" '#{}'

# --- (4) clojure.set/map-invert via the transient form (row 8.5 discharge) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(require '[clojure.set :as s])
(s/map-invert {:a 1 :b 2})
EOF
) || fail "(4): non-zero exit ($got)"
case "$(last_line "$got")" in
    "{1 :a, 2 :b}"|"{2 :b, 1 :a}") echo "PASS map_invert_transient_form -> $(last_line "$got")" ;;
    *) fail "(4): got '$(last_line "$got")'" ;;
esac

# --- (5) D-089: extend-type on a defrecord + ISeq -first reaches via slow-path (row 8.6 cycle 1) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Box [v])
(extend-type Box ISeq (-first [b] (get b :v)))
(first (->Box :hello))
EOF
) || fail "(5): non-zero exit ($got)"
assert_eq 'd089_iseq_extend_smoke' "$(last_line "$got")" ':hello'

# --- (6) D-089: native Tag IPersistentSet -disjoin reaches via slow-path (row 8.6 cycle 4) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def Long (rt/__native-type :integer))
(extend-type Long IPersistentSet (-disjoin [n k] :disj-on-int))
(disj 42 :x)
EOF
) || fail "(6): non-zero exit ($got)"
assert_eq 'd089_ips_extend_smoke' "$(last_line "$got")" ':disj-on-int'

# --- (7) dual-backend --compare on arithmetic (row 8.4 sanity) ---
got=$("$BIN" --compare -e '(+ 1 2 3)' 2>/dev/null) || fail "(7): non-zero exit ($got)"
case "$got" in
    OK*) echo "PASS compare_cli_arith_smoke -> $(echo "$got" | head -1)" ;;
    *) fail "(7): expected OK prefix, got '$got'" ;;
esac

# --- (8) bench gate wired-into-run_all proof: bench/quick.sh exits 0 ---
got=$(bash bench/quick.sh 2>&1 | tail -1)
case "$got" in
    *"Baseline rows appended"*|*"binary_size_bytes"*|*"us/run"*) echo "PASS bench_quick_runs_clean -> tail='$got'" ;;
    *) fail "(8): expected bench/quick.sh to finish cleanly, got '$got'" ;;
esac

echo "phase8_exit_smoke: 8/8 cases pass"
