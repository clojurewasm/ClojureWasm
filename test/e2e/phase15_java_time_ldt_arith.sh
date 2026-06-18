#!/usr/bin/env bash
# test/e2e/phase15_java_time_ldt_arith.sh — LocalDateTime arithmetic (D-462).
# plusDays/minusDays/plusWeeks/minusWeeks (epoch_day) + plusHours/plusMinutes/
# plusSeconds/plusNanos/minus* (nano_of_day with carry/borrow into epoch_day —
# crossing midnight rolls the day). All return a LocalDateTime. clj-grounded
# incl. the midnight-crossing carry/borrow edges. Uses `cljw -`. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
out() { "$BIN" - ; }

# --- day/week (epoch_day)
A=$(out <<'EOF' 2>&1
(println (str (.plusDays (java.time.LocalDateTime/of 2024 1 1 12 30) 40))
         (str (.minusDays (java.time.LocalDateTime/of 2024 3 1 12 0) 1))
         (str (.plusWeeks (java.time.LocalDateTime/of 2024 1 1 0 0) 2)))
EOF
)
eq 'day-week' "$A" '2024-02-10T12:30 2024-02-29T12:00 2024-01-15T00:00'

# --- time units with midnight carry/borrow
B=$(out <<'EOF' 2>&1
(println (str (.plusHours (java.time.LocalDateTime/of 2024 1 1 23 30) 2))      ; -> next day 01:30
         (str (.plusMinutes (java.time.LocalDateTime/of 2024 1 1 23 59) 2))    ; -> next day 00:01
         (str (.minusHours (java.time.LocalDateTime/of 2024 1 1 1 0) 2)))      ; -> prev day 23:00
(println (str (.plusSeconds (java.time.LocalDateTime/of 2024 1 1 0 0 30) 45))
         (str (.plusNanos (java.time.LocalDateTime/of 2024 1 1 12 0 0 0) 1500000000)))
EOF
)
eq 'time-carry' "$B" $'2024-01-02T01:30 2024-01-02T00:01 2023-12-31T23:00\n2024-01-01T00:01:15 2024-01-01T12:00:01.500'

echo "OK — phase15_java_time_ldt_arith (D-462) green"
