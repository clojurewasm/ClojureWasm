#!/usr/bin/env bash
# clojure.instant backfill (D-273). The `#inst` reader literal + Date print are cljw
# built-ins; this namespace exposes `read-instant-date` over the same canonical instant
# parser (clj-faithful — clj's read-instant-date also returns a Date). Malformed input
# throws. read-instant-timestamp / read-instant-calendar are deliberately NOT provided
# yet (no fake-Date collapse): the finished form is a neutral runtime/time model
# surfaced per-namespace (F-009), tracked in D-382.

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

# read-instant-date parses an instant string into a Date that equals the #inst literal.
got=$("$BIN" - <<'EOF' 2>/dev/null
(require 'clojure.instant)
(prn [(= (clojure.instant/read-instant-date "2026-06-10T12:00:00Z")
         #inst "2026-06-10T12:00:00.000-00:00")
      (class (clojure.instant/read-instant-date "2026-06-10"))])
EOF
)
assert_eq 'read_instant_date' "$got" '[true Date]'

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
