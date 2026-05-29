#!/usr/bin/env bash
# test/e2e/phase10_pprint.sh
#
# §9.12 row 10.2 — clojure.pprint minimum surface smoke. pprint returns
# nil (side-effect: prints to stdout); print-table returns nil
# (side-effect: prints rows). Tests verify var resolution + return value;
# side-effect stdout capture is blocked by a pre-existing println
# output-reach issue tracked as D-096.

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

# --- Case 1: pprint returns nil ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.pprint/pprint [1 2 3])
EOF
) || fail "pprint_returns_nil: non-zero exit"
assert_eq 'pprint_returns_nil' "$(last_line "$got")" 'nil'

# --- Case 2: print-table on empty returns nil ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.pprint/print-table [])
EOF
) || fail "print_table_empty: non-zero exit"
assert_eq 'print_table_empty_returns_nil' "$(last_line "$got")" 'nil'

# --- Case 3: pprint string ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.pprint/pprint "hello")
EOF
) || fail "pprint_string: non-zero exit"
assert_eq 'pprint_string_returns_nil' "$(last_line "$got")" 'nil'

# --- Case 4: pprint nil ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(clojure.pprint/pprint nil)
EOF
) || fail "pprint_nil: non-zero exit"
assert_eq 'pprint_nil_returns_nil' "$(last_line "$got")" 'nil'

echo "phase10_pprint: 4/4 cases pass"
