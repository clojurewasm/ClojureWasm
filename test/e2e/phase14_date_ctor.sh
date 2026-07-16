#!/usr/bin/env bash
# test/e2e/phase14_date_ctor.sh — java.util.Date constructor + .getTime (D-425).
# (java.util.Date.) = now; (java.util.Date. ms) = an epoch-ms Date. The VALUE is
# the #inst typed_instance (date.zig); .getTime reads the epoch-ms field, same as
# (inst-ms d). (class …) is the JVM FQCN "java.util.Date" (ADR-0174).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
assert_has() { local n="$1" g="$2" w="$3"; [[ "$g" == *"$w"* ]] || fail "$n: '$g' lacks '$w'"; echo "PASS $n =~ $w"; }

got=$("$BIN" - <<'EOF' 2>/dev/null
(def d (java.util.Date. 1577836800000))
(prn (str (class d)))               ; "java.util.Date" (ADR-0174 FQCN)
(prn d)                             ; #inst "2020-01-01T00:00:00.000-00:00"
(prn (.getTime d))                  ; 1577836800000
(prn (inst-ms d))                   ; 1577836800000 (same field)
(prn (= d #inst "2020-01-01T00:00:00.000-00:00"))  ; true
(prn (inst? d))                     ; true
(prn (pos? (.getTime (java.util.Date.))))          ; true (now > 0)
EOF
) || fail "date: non-zero exit ($got)"
assert_eq 'class_fqcn'  "$(sed -n '1p' <<< "$got")" '"java.util.Date"'
assert_eq 'prints_inst'   "$(sed -n '2p' <<< "$got")" '#inst "2020-01-01T00:00:00.000-00:00"'
assert_eq 'getTime'       "$(sed -n '3p' <<< "$got")" '1577836800000'
assert_eq 'inst_ms_same'  "$(sed -n '4p' <<< "$got")" '1577836800000'
assert_eq 'eq_inst_lit'   "$(sed -n '5p' <<< "$got")" 'true'
assert_eq 'inst_q'        "$(sed -n '6p' <<< "$got")" 'true'
assert_eq 'now_pos'       "$(sed -n '7p' <<< "$got")" 'true'

# non-integer ctor arg → type error.
assert_has 'ctor_type_err' "$("$BIN" -e '(java.util.Date. "x")' 2>&1 || true)" 'expected'

echo "OK — phase14_date_ctor (8 cases) green"
