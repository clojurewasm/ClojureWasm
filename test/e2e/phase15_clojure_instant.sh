#!/usr/bin/env bash
# clojure.instant backfill (D-273) + the neutral richer-instant model (D-382). The
# `#inst` reader literal + Date print are cljw built-ins; read-instant-date returns a
# Date (clj-faithful), read-instant-timestamp returns a real nanosecond-precision
# java.sql.Timestamp (neutral runtime/time/timestamp.zig, NOT a Date collapse — print
# form + class + inst?/inst-ms are clj-exact). read-instant-calendar is still absent
# (no Calendar type yet, D-382). Malformed input throws.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# read-instant-date parses an instant string into a Date that equals the #inst literal.
got=$("$BIN" - <<'EOF' 2>/dev/null
(require 'clojure.instant)
(prn [(= (clojure.instant/read-instant-date "2026-06-10T12:00:00Z")
         #inst "2026-06-10T12:00:00.000-00:00")
      (class (clojure.instant/read-instant-date "2026-06-10"))])
EOF
)
assert_eq 'read_instant_date' "$got" '[true Date]'

# read-instant-timestamp → a nanosecond-precision Timestamp (clj-exact print + class +
# inst?/inst-ms); a Timestamp is NOT = an =-instant Date (distinct type).
got=$("$BIN" - <<'EOF' 2>/dev/null
(require 'clojure.instant)
(let [ts (clojure.instant/read-instant-timestamp "2024-01-01T00:00:00.123456789Z")]
  (prn [ts (class ts) (inst? ts) (inst-ms ts)
        (= ts (clojure.instant/read-instant-timestamp "2024-01-01T00:00:00.123456789Z"))
        (= ts (clojure.instant/read-instant-date "2024-01-01T00:00:00.123Z"))]))
EOF
)
assert_eq 'read_instant_timestamp' "$got" '[#inst "2024-01-01T00:00:00.123456789-00:00" Timestamp true 1704067200123 true false]'

# Malformed input throws (clj parity: a bad instant string is rejected).
got=$("$BIN" - <<'EOF' 2>/dev/null
(require 'clojure.instant)
(print (try (clojure.instant/read-instant-date "not-an-instant") :no-throw
            (catch Exception e :threw)))
EOF
)
assert_eq 'malformed_throws' "$got" ':threw'

echo
echo "clojure.instant backfill (D-273) e2e: all green."
