#!/usr/bin/env bash
# test/e2e/phase9_cli.sh
#
# §9.11 row 9.5 — clojure.tools.cli/parse-opts minimum surface.

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

# --- Case 1: basic boolean + value options ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (get (clojure.tools.cli/parse-opts
  ["--port" "8080" "--verbose" "foo.clj"]
  [["-p" "--port PORT" "Port number"]
   ["-v" "--verbose" "Verbose output"]])
  :options))
EOF
) || fail "case1: non-zero exit"
case "$(last_line "$got")" in
    '{:port "8080", :verbose true}'|'{:verbose true, :port "8080"}') echo "PASS basic_opts -> $(last_line "$got")" ;;
    *) fail "case1: got '$(last_line "$got")'" ;;
esac

# --- Case 2: positional arguments captured ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (get (clojure.tools.cli/parse-opts
  ["--port" "8080" "file.clj" "other.clj"]
  [["-p" "--port PORT" "Port"]])
  :arguments))
EOF
) || fail "case2: non-zero exit"
assert_eq 'arguments_captured' "$(last_line "$got")" '["file.clj" "other.clj"]'

# --- Case 3: unknown option lands in :errors ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (get (clojure.tools.cli/parse-opts
  ["--unknown"]
  [["-p" "--port PORT" "Port"]])
  :errors))
EOF
) || fail "case3: non-zero exit"
# clj-faithful error format (pr-str quoting; oracle-verified vs JVM tools.cli).
assert_eq 'unknown_option_error' "$(last_line "$got")" '["Unknown option: \"--unknown\""]'

# --- Case 4: --name=value form ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (get (clojure.tools.cli/parse-opts
  ["--port=9090"]
  [["-p" "--port PORT" "Port"]])
  :options))
EOF
) || fail "case4: non-zero exit"
assert_eq 'eq_form' "$(last_line "$got")" '{:port "9090"}'

# --- Case 5: short flag boolean ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (get (clojure.tools.cli/parse-opts
  ["-v"]
  [["-v" "--verbose" "Verbose"]])
  :options))
EOF
) || fail "case5: non-zero exit"
assert_eq 'short_bool' "$(last_line "$got")" '{:verbose true}'

# --- Case 6: missing value raises error ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (get (clojure.tools.cli/parse-opts
  ["--port"]
  [["-p" "--port PORT" "Port"]])
  :errors))
EOF
) || fail "case6: non-zero exit"
# clj-faithful error format (oracle-verified vs JVM tools.cli).
assert_eq 'missing_value_error' "$(last_line "$got")" '["Missing required argument for \"--port PORT\""]'

# --- Case 7: summary string includes both opts ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (get (clojure.tools.cli/parse-opts
  []
  [["-p" "--port PORT" "Port"]
   ["-v" "--verbose" "Verbose"]])
  :summary))
EOF
) || fail "case7: non-zero exit"
assert_eq 'summary_lines' "$(last_line "$got")" '"  -p, --port PORT  Port\n  -v, --verbose    Verbose"'

echo "phase9_cli: 7/7 cases pass"
