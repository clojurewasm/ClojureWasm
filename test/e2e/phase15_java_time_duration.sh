#!/usr/bin/env bash
# test/e2e/phase15_java_time_duration.sh — java.time.Duration wiring (D-462).
# Duration is a `.typed_instance` (instant_value.zig model: per-Runtime
# descriptor + TWO fields seconds + nanos, NORMALIZED so nanos∈[0,1e9) and
# seconds carries the sign). Factories ofSeconds[/nanos]/ofMillis/ofNanos/
# ofMinutes/ofHours/ofDays; instance getSeconds/getNano/toMillis/toMinutes.
# `(str d)` = ISO-8601 duration `PT…` (the exact JDK Duration.toString),
# clj-grounded. Uses `cljw -` (stdin). Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }
out() { "$BIN" - ; }

# --- str: the full PT-format surface (positive, negative, fractional)
A=$(out <<'EOF' 2>&1
(doseq [d [(java.time.Duration/ofSeconds 90)
           (java.time.Duration/ofHours 2)
           (java.time.Duration/ofMinutes 90)
           (java.time.Duration/ofMillis 1500)
           (java.time.Duration/ofSeconds 5 500000000)
           (java.time.Duration/ofSeconds 0)
           (java.time.Duration/ofSeconds -30)
           (java.time.Duration/ofSeconds 3661)
           (java.time.Duration/ofSeconds -3661)
           (java.time.Duration/ofMillis -1500)
           (java.time.Duration/ofSeconds -1 500000000)
           (java.time.Duration/ofNanos 123456789)
           (java.time.Duration/ofDays 1)]]
  (println (str d)))
EOF
)
eq 'str-forms' "$A" $'PT1M30S\nPT2H\nPT1H30M\nPT1.5S\nPT5.5S\nPT0S\nPT-30S\nPT1H1M1S\nPT-1H-1M-1S\nPT-1.5S\nPT-0.5S\nPT0.123456789S\nPT24H'

# --- readers: normalized fields + toMillis/toMinutes
B=$(out <<'EOF' 2>&1
(let [d (java.time.Duration/ofMillis -1500)]
  (println (.getSeconds d) (.getNano d) (.toMillis d)))
(let [d (java.time.Duration/ofSeconds 90)]
  (println (.getSeconds d) (.getNano d) (.toMillis d) (.toMinutes d)))
EOF
)
eq 'readers' "$B" $'-2 500000000 -1500\n90 0 90000 1'

# --- value =: by normalized seconds + nanos
C=$(out <<'EOF' 2>&1
(println (= (java.time.Duration/ofSeconds 90) (java.time.Duration/ofMillis 90000)))
(println (= (java.time.Duration/ofSeconds 90) (java.time.Duration/ofSeconds 91)))
EOF
)
eq 'value-eq' "$C" $'true\nfalse'

echo "OK — phase15_java_time_duration (D-462) green"
