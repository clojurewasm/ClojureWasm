#!/usr/bin/env bash
# test/e2e/phase14_cljc_libspec.sh
#
# D-300 — cljc libspec leniency (clj parity, oracle-confirmed). JVM clj IGNORES
# the cljs-only LIBSPEC keywords :include-macros / :refer-macros / :require-macros
# when they appear inside a `[ns …]` libspec, so a .cljc library loads on the JVM
# (schema.core:84 `[schema.spec.core :as spec :include-macros true]`). But the
# top-level `(:require-macros …)` DIRECTIVE is REJECTED by clj on the JVM
# (well-formed cljc guards it with a reader conditional) — cljw matches both.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# --- libspec macro-keywords are tolerated (ignored), require still works ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(ns t (:require [clojure.set :as s :include-macros true :refer-macros [union] :require-macros true]))
(prn (s/union #{1 2} #{2 9}))
EOF
) || fail "libspec_macro_keywords: non-zero exit ($got)"
assert_eq 'libspec_macro_keywords' "$(last_line "$got")" '#{1 2 9}'

# --- :include-macros alone (the schema.core shape) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(ns t2 (:require [clojure.set :as s :include-macros true]))
(prn (s/intersection #{1 2 3} #{2 3 4}))
EOF
) || fail "include_macros_only: non-zero exit ($got)"
# Set print order is cljw hash order (AD-001), not clj's — assert cljw's.
assert_eq 'include_macros_only' "$(last_line "$got")" '#{2 3}'

# --- the (:require-macros …) DIRECTIVE is rejected (clj parity) ---
if "$BIN" -e "(ns t3 (:require-macros [clojure.set]))" >/dev/null 2>&1; then
    fail "require_macros_directive_rejected: expected non-zero exit (clj rejects it on JVM)"
fi
echo "PASS require_macros_directive_rejected"
