#!/usr/bin/env bash
# test/e2e/phase15_java_time_sort.sh — (compare …)/(sort …) on java.time values
# (D-462). compare.zig grew a per-type temporal arm (mirrors the equal.zig arms),
# so temporal values are Comparable. cljw's compare is SIGN-based (Order -1/0/1)
# — clj returns a field-difference MAGNITUDE for LocalDate/LocalDateTime and a
# char-difference for strings; both are Comparable-contract-equal (sign only),
# recorded as AD-043. This test pins cljw's sign behavior. Uses `cljw -`. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
out() { "$BIN" - ; }

# --- compare returns the sign (-1/0/1) for every temporal type
A=$(out <<'EOF' 2>&1
(println (compare (java.time.Instant/ofEpochSecond 5) (java.time.Instant/ofEpochSecond 9))
         (compare (java.time.Instant/ofEpochSecond 9) (java.time.Instant/ofEpochSecond 5))
         (compare (java.time.Instant/ofEpochSecond 5) (java.time.Instant/ofEpochSecond 5)))
(println (compare (java.time.LocalDate/of 2024 6 1) (java.time.LocalDate/of 2024 1 1))
         (compare (java.time.LocalTime/of 6 0) (java.time.LocalTime/of 18 0))
         (compare (java.time.Duration/ofSeconds 1) (java.time.Duration/ofSeconds 9))
         (compare (java.time.LocalDateTime/of 2024 1 1 6 0) (java.time.LocalDateTime/of 2024 1 1 18 0)))
EOF
)
eq 'compare-sign' "$A" $'-1 1 0\n1 -1 -1 -1'

# --- sort works on temporal values (the headline payoff)
B=$(out <<'EOF' 2>&1
(println (mapv str (sort [(java.time.LocalDate/of 2024 6 1) (java.time.LocalDate/of 2024 1 1) (java.time.LocalDate/of 2024 3 1)])))
EOF
)
eq 'sort' "$B" '[2024-01-01 2024-03-01 2024-06-01]'

# --- AD-043 pin: cljw compare is sign-based for strings too (clj -> char diff)
C=$(out <<'EOF' 2>&1
(println (compare "a" "c"))
EOF
)
eq 'sign-string' "$C" '-1'

echo "OK — phase15_java_time_sort (D-462) green"
