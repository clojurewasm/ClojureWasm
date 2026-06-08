#!/usr/bin/env bash
# test/e2e/phase7_replace_pattern_a.sh
#
# Phase 7 §9.9 row 7.12 cycle 3 — `clojure.string/replace` +
# `replace-first` Pattern A landing (D-078 close). The public
# Vars now resolve to .clj `defn`s that dispatch via `(cond
# (instance? String match) ... (instance? Pattern match) ...)`
# across the 6 `-str-replace-*` private leaves landed at cycle 2.
# Regex-string `$N` interpretation deferred to D-051 cycle 3
# (PROVISIONAL marker on `-str-replace-pattern`).

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

# --- Case 1: string-string match (replace all) ---
got=$("$BIN" -e '(clojure.string/replace "hello world hello" "hello" "HI")' 2>/dev/null)
assert_eq 'replace_string_string_all' "$got" '"HI world HI"'

# --- Case 2: string-string match (replace-first) ---
got=$("$BIN" -e '(clojure.string/replace-first "abc abc abc" "abc" "XYZ")' 2>/dev/null)
assert_eq 'replace_first_string_string' "$got" '"XYZ abc abc"'

# --- Case 3: regex-fn match (whole-match callable) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.string/replace "abc123def456ghi" #"\d+" (fn* [m] (str "<" m ">"))))
EOF
)
assert_eq 'replace_regex_fn' "$got" '"abc<123>def<456>ghi"'

# --- Case 4: regex-fn replace-first stops after first match ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.string/replace-first "abc123def456ghi" #"\d+" (fn* [m] (str "<" m ">"))))
EOF
)
assert_eq 'replace_first_regex_fn' "$got" '"abc<123>def456ghi"'

# --- Case 5: $0 is the whole match (D-093 discharge — was a literal PROVISIONAL) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.string/replace "abc123" #"\d+" "$0"))
EOF
)
assert_eq 'replace_regex_string_dollar_zero' "$got" '"abc123"'

# --- Case 6: unsupported match type raises (cond :else clause) ---
# The top-level renders the thrown ex-info's message + the `exception`
# label (ADR-0055 am2 / D-144) — surfacing the ex-info message at the
# CLI tail, not the old generic "ThrownValue". The :else clause being
# reached at all is what this case verifies — that the cond did not
# silently fall through.
diag=$("$BIN" -e '(clojure.string/replace "abc" 42 "X")' 2>&1 || true)
case "$diag" in
    *"Exception"*"replace: unsupported match type"*)
        echo "PASS replace_unsupported_match_raises -> ex-info message surfaced" ;;
    *)
        fail "replace_unsupported_match_raises: missing ex-info message ($diag)" ;;
esac

# --- Case 7: unsupported match round-trips through (try ... (catch
#     ExceptionInfo ...)) so the ex-info message IS reachable ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (try (clojure.string/replace "abc" 42 "X")
  (catch ExceptionInfo e (ex-message e))))
EOF
)
assert_eq 'replace_unsupported_caught' "$got" '"replace: unsupported match type"'

# --- $N capture-group backreferences in the replacement (D-093 discharge) ---
got=$("$BIN" -e '(clojure.string/replace "abc" #"(.)" "$1$1")' 2>/dev/null)
assert_eq 'replace_dollar_group_double' "$got" '"aabbcc"'
got=$("$BIN" -e '(clojure.string/replace "2024-01" #"(\d+)-(\d+)" "$2/$1")' 2>/dev/null)
assert_eq 'replace_dollar_swap' "$got" '"01/2024"'
got=$("$BIN" -e '(clojure.string/replace "x" #"(x)" "$0!")' 2>/dev/null)
assert_eq 'replace_dollar_zero_whole' "$got" '"x!"'
got=$("$BIN" -e '(clojure.string/replace "ab" #"a(b)?" "[$1]")' 2>/dev/null)
assert_eq 'replace_dollar_nonparticipating' "$got" '"[b]"'
# --- fn replacement receives the match vector when the pattern has groups ---
got=$("$BIN" -e '(clojure.string/replace "ab" #"(\w)" (fn [[whole g1]] (clojure.string/upper-case g1)))' 2>/dev/null)
assert_eq 'replace_fn_match_vector' "$got" '"AB"'

echo
echo "Phase 7 row 7.12 cycle 3 replace Pattern A e2e: all green."
