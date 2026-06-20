#!/usr/bin/env bash
# test/e2e/phase15_java_time_local_date_arith.sh — LocalDate arithmetic (D-462).
# plusDays/minusDays/plusWeeks/minusWeeks (epoch_day math) + plusMonths/
# minusMonths/plusYears/minusYears (civil math with day-clamping to month length,
# the JVM LocalDate semantics) + isLeapYear/lengthOfMonth. All return a LocalDate
# (or bool/int). clj-grounded incl. the leap/clamp edges. Uses `cljw -`. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
out() { "$BIN" - ; }

# --- day/week arithmetic (epoch_day)
A=$(out <<'EOF' 2>&1
(println (str (.plusDays (java.time.LocalDate/of 2024 1 1) 40))
         (str (.minusDays (java.time.LocalDate/of 2024 1 1) 1))
         (str (.plusWeeks (java.time.LocalDate/of 2024 1 1) 2))
         (str (.minusWeeks (java.time.LocalDate/of 2024 1 15) 2)))
EOF
)
eq 'day-week' "$A" '2024-02-10 2023-12-31 2024-01-15 2024-01-01'

# --- month/year arithmetic with day-clamping (civil)
B=$(out <<'EOF' 2>&1
(println (str (.plusMonths (java.time.LocalDate/of 2024 1 31) 1))     ; -> 2024-02-29 (leap clamp)
         (str (.plusMonths (java.time.LocalDate/of 2023 1 31) 1))     ; -> 2023-02-28
         (str (.plusMonths (java.time.LocalDate/of 2024 12 15) 1))    ; -> 2025-01-15 (year rollover)
         (str (.minusMonths (java.time.LocalDate/of 2024 3 31) 1)))   ; -> 2024-02-29
(println (str (.plusYears (java.time.LocalDate/of 2024 2 29) 1))      ; -> 2025-02-28 (leap clamp)
         (str (.minusYears (java.time.LocalDate/of 2024 6 15) 5)))    ; -> 2019-06-15
EOF
)
eq 'month-year' "$B" $'2024-02-29 2023-02-28 2025-01-15 2024-02-29\n2025-02-28 2019-06-15'

# --- isLeapYear / lengthOfMonth
C=$(out <<'EOF' 2>&1
(println (.isLeapYear (java.time.LocalDate/of 2024 1 1))
         (.isLeapYear (java.time.LocalDate/of 2023 1 1))
         (.isLeapYear (java.time.LocalDate/of 1900 1 1))
         (.isLeapYear (java.time.LocalDate/of 2000 1 1)))
(println (.lengthOfMonth (java.time.LocalDate/of 2024 2 1))
         (.lengthOfMonth (java.time.LocalDate/of 2023 2 1))
         (.lengthOfMonth (java.time.LocalDate/of 2024 4 1)))
EOF
)
eq 'leap-length' "$C" $'true false false true\n29 28 30'

# --- atStartOfDay / atTime → LocalDateTime (D-462 residual 2; clj-grounded)
D=$(out <<'EOF' 2>&1
(let [d (java.time.LocalDate/of 2026 6 20)]
  (println (str (.atStartOfDay d)))           ; -> 2026-06-20T00:00
  (println (str (.atTime d 13 30)))           ; -> 2026-06-20T13:30
  (println (str (.atTime d 13 30 45)))        ; -> 2026-06-20T13:30:45
  (println (str (.atTime d 0 0 0 500000000))) ; -> 2026-06-20T00:00:00.500
  (println (str (.toLocalDate (.atTime d 13 30)))))  ; round-trip -> 2026-06-20
EOF
)
eq 'at-time' "$D" $'2026-06-20T00:00\n2026-06-20T13:30\n2026-06-20T13:30:45\n2026-06-20T00:00:00.500\n2026-06-20'

echo "OK — phase15_java_time_local_date_arith (D-462) green"
