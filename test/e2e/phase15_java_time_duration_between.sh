#!/usr/bin/env bash
# test/e2e/phase15_java_time_duration_between.sh — cross-type Duration ops (D-462):
# (Duration/between a b) (elapsed time; dispatches on the temporal type — Instant/
# LocalDateTime/LocalTime) and Instant/LocalDateTime .plus(Duration)/.minus(Duration)
# (deadlines, with carry). The two most common temporal computations. clj-grounded.
# Uses `cljw -` (stdin). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
out() { "$BIN" - ; }

# --- Duration/between (elapsed time) across the point types
A=$(out <<'EOF' 2>&1
(println (str (java.time.Duration/between (java.time.Instant/ofEpochSecond 100) (java.time.Instant/ofEpochSecond 190)))
         (str (java.time.Duration/between (java.time.Instant/ofEpochSecond 190) (java.time.Instant/ofEpochSecond 100)))
         (str (java.time.Duration/between (java.time.LocalDateTime/of 2024 1 1 12 0) (java.time.LocalDateTime/of 2024 1 1 13 30)))
         (str (java.time.Duration/between (java.time.LocalTime/of 6 0) (java.time.LocalTime/of 8 30))))
EOF
)
eq 'between' "$A" 'PT1M30S PT-1M-30S PT1H30M PT2H30M'

# --- Instant .plus/.minus (Duration)
B=$(out <<'EOF' 2>&1
(println (str (.plus (java.time.Instant/ofEpochSecond 100) (java.time.Duration/ofSeconds 5 500000000)))
         (str (.minus (java.time.Instant/ofEpochSecond 100) (java.time.Duration/ofSeconds 50))))
EOF
)
eq 'instant-plus-dur' "$B" '1970-01-01T00:01:45.500Z 1970-01-01T00:00:50Z'

# --- LocalDateTime .plus (Duration), with day carry
C=$(out <<'EOF' 2>&1
(println (str (.plus (java.time.LocalDateTime/of 2024 1 1 23 0) (java.time.Duration/ofHours 2)))
         (str (.minus (java.time.LocalDateTime/of 2024 1 2 1 0) (java.time.Duration/ofHours 2))))
EOF
)
eq 'ldt-plus-dur' "$C" '2024-01-02T01:00 2024-01-01T23:00'

echo "OK — phase15_java_time_duration_between (D-462) green"
