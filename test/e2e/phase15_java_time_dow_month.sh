#!/usr/bin/env bash
# test/e2e/phase15_java_time_dow_month.sh — LocalDate/LocalDateTime getDayOfWeek /
# getMonth / getDayOfYear (D-462 / ADR-0161). DayOfWeek + Month are host-enum
# singletons (.host_instance, ordinal in state[0]; (str)/.name = enum NAME, getValue
# → ISO int; static fields DayOfWeek/MONDAY etc; getters return the SAME interned
# singleton as the constant — identical? parity). getDayOfYear returns an int (no
# enum). clj-grounded. Uses `cljw -` (stdin). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
out() { "$BIN" - ; }

# --- LocalDate getDayOfWeek / getMonth / getDayOfYear
A=$(out <<'EOF' 2>&1
(let [d (java.time.LocalDate/of 2024 3 9)]
  (println (str (.getDayOfWeek d)) (.getValue (.getDayOfWeek d))
           (str (.getMonth d)) (.getValue (.getMonth d))
           (.getDayOfYear d)))
EOF
)
eq 'localdate' "$A" 'SATURDAY 6 MARCH 3 69'

# --- LocalDateTime getDayOfWeek / getMonth
B=$(out <<'EOF' 2>&1
(let [dt (java.time.LocalDateTime/of 2024 12 25 10 0)]
  (println (str (.getDayOfWeek dt)) (str (.getMonth dt))))
EOF
)
eq 'localdatetime' "$B" 'WEDNESDAY DECEMBER'

# --- enum value-= (two Saturdays equal; different days not)
C=$(out <<'EOF' 2>&1
(println (= (.getDayOfWeek (java.time.LocalDate/of 2024 3 9)) (.getDayOfWeek (java.time.LocalDate/of 2024 3 16)))
         (= (.getMonth (java.time.LocalDate/of 2024 3 9)) (.getMonth (java.time.LocalDate/of 2024 4 9))))
EOF
)
eq 'enum-eq' "$C" 'true false'

# --- Sunday boundary (ISO Mon=1..Sun=7); epoch day 0 = Thursday
D=$(out <<'EOF' 2>&1
(println (str (.getDayOfWeek (java.time.LocalDate/of 1970 1 1)))      ; Thursday
         (str (.getDayOfWeek (java.time.LocalDate/of 2024 3 10))))    ; Sunday
EOF
)
eq 'dow-boundary' "$D" 'THURSDAY SUNDAY'

# --- ChronoUnit enum constants: (str)=display name, (.name)=enum name, = (D-511/D-510)
E=$(out <<'EOF' 2>&1
(println (str java.time.temporal.ChronoUnit/DAYS)
         (.name java.time.temporal.ChronoUnit/DAYS)
         (str java.time.temporal.ChronoUnit/HALF_DAYS)
         (.name java.time.temporal.ChronoUnit/MILLENNIA)
         (= java.time.temporal.ChronoUnit/DAYS java.time.temporal.ChronoUnit/DAYS)
         (= java.time.temporal.ChronoUnit/DAYS java.time.temporal.ChronoUnit/WEEKS))
EOF
)
eq 'chrono-unit' "$E" 'Days DAYS HalfDays MILLENNIA true false'

# --- LocalDate.until(d2, ChronoUnit) — date-unit diffs; day-of-month boundary
F=$(out <<'EOF' 2>&1
(let [a (java.time.LocalDate/of 2020 1 1) b (java.time.LocalDate/of 2021 3 15)]
  (println (.until a b java.time.temporal.ChronoUnit/DAYS)
           (.until a b java.time.temporal.ChronoUnit/WEEKS)
           (.until a b java.time.temporal.ChronoUnit/MONTHS)
           (.until a b java.time.temporal.ChronoUnit/YEARS)
           ; Jan31->Mar1 is NOT a full 2 months (day-of-month boundary)
           (.until (java.time.LocalDate/of 2020 1 31) (java.time.LocalDate/of 2020 3 1) java.time.temporal.ChronoUnit/MONTHS)
           ; negative direction
           (.until (java.time.LocalDate/of 2020 3 1) (java.time.LocalDate/of 2020 1 1) java.time.temporal.ChronoUnit/DAYS)))
EOF
)
eq 'until' "$F" '439 62 14 1 1 -60'

# --- a time-based unit on a LocalDate raises (JVM UnsupportedTemporalTypeException)
G=$("$BIN" -e '(.until (java.time.LocalDate/of 2020 1 1) (java.time.LocalDate/of 2020 1 2) java.time.temporal.ChronoUnit/HOURS)' 2>&1 || true)
case "$G" in
    *"date-based"*|*"ChronoUnit"*) echo "PASS until-unsupported -> raised" ;;
    *) fail "until-unsupported: expected a date-based-unit error, got '$G'" ;;
esac

# --- LocalDateTime.until — date units (time-of-day adjusted) + time units (D-512)
H=$(out <<'EOF' 2>&1
(let [a (java.time.LocalDateTime/of 2020 1 1 0 0 0) b (java.time.LocalDateTime/of 2021 3 2 6 30 15)]
  (println (.until a b java.time.temporal.ChronoUnit/DAYS)
           (.until a b java.time.temporal.ChronoUnit/HOURS)
           (.until a b java.time.temporal.ChronoUnit/MINUTES)
           (.until a b java.time.temporal.ChronoUnit/SECONDS)
           (.until a b java.time.temporal.ChronoUnit/MONTHS)
           (.until a b java.time.temporal.ChronoUnit/YEARS)))
EOF
)
eq 'ldt-until' "$H" '426 10230 613830 36829815 14 1'

# --- DayOfWeek/Month static-field enum constants (ADR-0161 / D-510): name / getValue
I=$(out <<'EOF' 2>&1
(println (str java.time.DayOfWeek/MONDAY) (.getValue java.time.DayOfWeek/SUNDAY) (.name java.time.DayOfWeek/MONDAY)
         (str java.time.Month/JANUARY) (.getValue java.time.Month/DECEMBER) (.name java.time.Month/MARCH))
EOF
)
eq 'enum-const' "$I" 'MONDAY 7 MONDAY JANUARY 12 MARCH'

# --- getter returns the SAME interned singleton as the constant (clj identical? parity)
J=$(out <<'EOF' 2>&1
(println (= (.getDayOfWeek (java.time.LocalDate/of 2024 3 9)) java.time.DayOfWeek/SATURDAY)
         (identical? (.getDayOfWeek (java.time.LocalDate/of 2024 3 9)) java.time.DayOfWeek/SATURDAY)
         (= (.getMonth (java.time.LocalDate/of 2024 3 9)) java.time.Month/MARCH)
         (identical? (.getMonth (java.time.LocalDate/of 2024 3 9)) java.time.Month/MARCH))
EOF
)
eq 'enum-identity' "$J" 'true true true true'

# --- host-enum Comparable: sign-based compare (AD-043) + sort by ordinal
K=$(out <<'EOF' 2>&1
(println (compare java.time.DayOfWeek/MONDAY java.time.DayOfWeek/SUNDAY)
         (compare java.time.Month/MARCH java.time.Month/JANUARY)
         (compare java.math.RoundingMode/UP java.math.RoundingMode/DOWN)
         (mapv str (sort [java.time.DayOfWeek/WEDNESDAY java.time.DayOfWeek/MONDAY java.time.DayOfWeek/FRIDAY])))
EOF
)
eq 'enum-compare' "$K" '-1 1 -1 [MONDAY WEDNESDAY FRIDAY]'

echo "OK — phase15_java_time_dow_month (D-462 / ADR-0161) green"
