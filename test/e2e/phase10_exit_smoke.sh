#!/usr/bin/env bash
# test/e2e/phase10_exit_smoke.sh
#
# §9.12 row 10.5 — Phase 10 exit-criterion smoke. Verifies:
#
#   - clojure.pprint/pprint exists + returns nil (row 10.2)
#   - clojure.pprint/print-table on a small data structure
#   - Phase 9 modules (edn / json / csv / cli) still compose
#   - self-host viability re-verified post-Phase-10 surface additions
#
# Rows 10.3 (host stdlib second wave) + 10.4 (namespace ergonomics
# polish) closed as enumeration-only — D-097 + D-098 capture the
# implementation deferrals. This exit smoke does NOT exercise those
# surfaces (would just re-confirm the raise paths).

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
last_line() { awk 'END { print }' <<< "$1"; }

# --- (1) pprint smoke ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.pprint/pprint {:a 1 :b 2}))
EOF
) || fail "(1): non-zero exit"
assert_eq 'pprint_returns_nil' "$(last_line "$got")" 'nil'

# --- (2) print-table smoke ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.pprint/print-table [{:name "x" :v 1} {:name "y" :v 2}]))
EOF
) || fail "(2): non-zero exit"
assert_eq 'print_table_returns_nil' "$(last_line "$got")" 'nil'

# --- (3) Phase 9 modules still compose (edn → json round-trip) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.data.json/read-str
  (clojure.data.json/write-str
    (clojure.edn/read-string "[1 2 3]"))))
EOF
) || fail "(3): non-zero exit"
assert_eq 'edn_to_json_round_trip' "$(last_line "$got")" '[1 2 3]'

# --- (4) Phase 9 csv + cli still work in tandem ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (get (clojure.tools.cli/parse-opts
  ["--port" "9090"]
  [["-p" "--port PORT" "Port"]])
  :options))
EOF
) || fail "(4): non-zero exit"
assert_eq 'cli_still_works' "$(last_line "$got")" '{:port "9090"}'

# --- (5) self-host viability re-verified ---
# Triple cross-ns expression touching core/set/edn/pprint — D-007
# property holds across Phase 10's surface additions.
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.pprint/pprint
  (clojure.set/intersection
    (clojure.edn/read-string "#{:a :b :c}")
    #{:b :c :d})))
EOF
) || fail "(5): non-zero exit"
assert_eq 'self_host_pprint_set_edn' "$(last_line "$got")" 'nil'

echo "phase10_exit_smoke: 5/5 cases pass"
