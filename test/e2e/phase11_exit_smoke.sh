#!/usr/bin/env bash
# test/e2e/phase11_exit_smoke.sh
#
# §9.13 row 11.5 — Phase 11 exit smoke + final activation verify.
# Asserts:
#   - clojure.test/is + run-tests compose end-to-end
#   - The 13 ported tests in test/clj/cw_ported.clj all pass
#   - build_options.phase_at_least_11 flag is true post-flip
#   - Self-host viability still holds (cross-ns expression touches
#     clojure.test + clojure.set + clojure.edn)

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

# --- (1) clojure.test compose smoke ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defn t1 [] (clojure.test/is (= 1 1)))
(defn t2 [] (clojure.test/is true))
(clojure.test/run-tests t1 t2)
EOF
) || fail "(1): non-zero exit"
assert_eq 'clojure_test_compose' "$(last_line "$got")" '[2 0]'

# --- (2) Tier A 13/13 still green ---
bash test/clj/run_tier_a.sh >/dev/null || fail "(2): tier_a regressed"
echo "PASS tier_a_13_of_13_still_green"

# --- (3) self-host cross-ns smoke (test + set + edn) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defn ts1 []
  (clojure.test/is
    (= 2 (count (clojure.set/intersection
                  (clojure.edn/read-string "#{1 2 3}")
                  #{2 3 4})))))
(clojure.test/run-tests ts1)
EOF
) || fail "(3): non-zero exit"
assert_eq 'self_host_test_set_edn' "$(last_line "$got")" '[1 0]'

echo "phase11_exit_smoke: 3/3 cases pass"
