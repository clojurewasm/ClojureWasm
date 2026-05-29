#!/usr/bin/env bash
# test/e2e/phase9_exit_smoke.sh
#
# §9.11 row 9.6 — Phase 9 exit-criterion smoke. Verifies the
# headline end-to-end paths the Phase 9 Exit criterion enumerates:
#
#   - clojure.edn/read-string round-trip (row 9.2)
#   - clojure.data.json/{read-str,write-str} round-trip (row 9.3)
#   - clojure.data.csv/{read-csv,write-csv} round-trip (row 9.4)
#   - clojure.tools.cli/parse-opts smoke (row 9.5)
#   - zone_check.sh --gate (modules/ dependency direction)
#   - D-007 self-host viability (cw bootstraps all 9 embedded
#     namespaces every cljw invocation; if that crashed, no test
#     in the gate would run — this row pins the property).
#
# Per-feature e2e:
#   - phase9_edn_read_string.sh
#   - phase9_json.sh
#   - phase9_csv.sh
#   - phase9_cli.sh

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

# --- (1) EDN round-trip ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.edn/read-string "[1 2 3]")
EOF
) || fail "(1): non-zero exit"
assert_eq 'edn_round_trip' "$(last_line "$got")" '[1 2 3]'

# --- (2) JSON round-trip ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.json/read-str (clojure.data.json/write-str [1 "x" nil true]))
EOF
) || fail "(2): non-zero exit"
assert_eq 'json_round_trip' "$(last_line "$got")" '[1 "x" nil true]'

# --- (3) CSV round-trip ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.data.csv/read-csv (clojure.data.csv/write-csv [["a" "b,c"] ["d" "e\"f"]]))
EOF
) || fail "(3): non-zero exit"
assert_eq 'csv_round_trip' "$(last_line "$got")" '[["a" "b,c"] ["d" "e\"f"]]'

# --- (4) tools.cli parse-opts smoke ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(get (clojure.tools.cli/parse-opts
  ["--port" "8080" "input.clj"]
  [["-p" "--port PORT" "Port"]])
  :options)
EOF
) || fail "(4): non-zero exit"
assert_eq 'cli_parse_opts_smoke' "$(last_line "$got")" '{:port "8080"}'

# --- (5) modules/ zone-check gate ---
bash scripts/zone_check.sh --gate >/dev/null 2>&1 || fail "(5): zone_check.sh --gate failed"
echo "PASS modules_zone_check_gate"

# --- (6) D-007 self-host viability ---
# cw v1's bootstrap loads 9 embedded .clj namespaces every invocation
# (core/string/set/walk/zip/edn/data.json/data.csv/tools.cli). If the
# self-host path were broken, NO e2e test in the gate could run. This
# probe checks the property explicitly by requiring a value that crosses
# clojure.core (defn / let / fn) + clojure.set (intersection) +
# clojure.edn (read-string) — three distinct embedded namespaces.
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.set/intersection
  #{1 2 3}
  (clojure.edn/read-string "#{2 3 4}"))
EOF
) || fail "(6): non-zero exit"
case "$(last_line "$got")" in
    "#{2 3}"|"#{3 2}") echo "PASS self_host_cross_ns -> $(last_line "$got")" ;;
    *) fail "(6): got '$(last_line "$got")'" ;;
esac

echo "phase9_exit_smoke: 6/6 cases pass"
