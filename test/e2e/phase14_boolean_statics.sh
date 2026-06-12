#!/usr/bin/env bash
# test/e2e/phase14_boolean_statics.sh
#
# Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) —
# java.lang.Boolean statics, completing the java.lang scalar-class static
# cluster (Integer/Long/Double/Character/Boolean). Surface
# runtime/java/lang/Boolean.zig.
#
# Boolean.parseBoolean is case-INSENSITIVE "true" → true, anything else →
# false (NOT nil) — distinct from clojure.core/parse-boolean (strict,
# nil on miss), so it is NOT a delegation. Boolean/TRUE / FALSE are bool
# static fields (ADR-0061 + the StaticFieldValue.bool extension).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

check() { # check <expr> <expected> <label>
    local out
    set +e
    out=$("$BIN" -e "$1" 2>&1 | tail -n 1)
    set -e
    [[ "$out" == "$2" ]] || fail "$3: expected '$2', got '$out'"
    echo "PASS $3 -> $2"
}

# --- parseBoolean: case-insensitive "true" → true, else false (never nil) ---
check '(Boolean/parseBoolean "true")'  'true'  boolean_parse_true
check '(Boolean/parseBoolean "false")' 'false' boolean_parse_false
check '(Boolean/parseBoolean "TRUE")'  'true'  boolean_parse_caseins
check '(Boolean/parseBoolean "yes")'   'false' boolean_parse_other_false

# --- valueOf (string parses; boolean identity) ---
check '(Boolean/valueOf "true")'       'true'  boolean_valueOf_string
check '(Boolean/valueOf false)'        'false' boolean_valueOf_bool

# --- toString ---
check '(Boolean/toString true)'        '"true"'  boolean_toString_true
check '(Boolean/toString false)'       '"false"' boolean_toString_false

# --- TRUE / FALSE static fields (ADR-0061 bool variant) ---
check 'Boolean/TRUE'   'true'  boolean_true_field
check 'Boolean/FALSE'  'false' boolean_false_field
check '(if Boolean/TRUE :yes :no)' ':yes' boolean_true_in_expr

echo "ALL PASS phase14_boolean_statics"
