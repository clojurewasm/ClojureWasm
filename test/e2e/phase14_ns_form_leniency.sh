#!/usr/bin/env bash
# test/e2e/phase14_ns_form_leniency.sh
#
# D-299 — ns-form leniency (clj parity): the ns macro accepts
#   (1) a list-OR-vector argument to :refer-clojure :exclude / :only
#       (`(:refer-clojure :exclude (vec))` as well as `[vec]`), and
#   (2) a vector-headed ns directive `[:require …]` as well as the list form
#       `(:require …)` (clojure.core's own string.clj uses the vector form).
# Unblocked clojure.data.zip (loads).

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

# --- (1) list-arg :refer-clojure :exclude (the user can then define its own) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(ns t1 (:refer-clojure :exclude (vec inc)))
(defn inc [x] :my-inc)
(prn [(inc 5) (clojure.core/inc 5)])
EOF
) || fail "exclude_list_arg: non-zero exit ($got)"
assert_eq 'exclude_list_arg' "$(last_line "$got")" '[:my-inc 6]'

# --- (2) vector-headed ns directive ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(ns t2 [:require [clojure.set :as s]])
(prn (s/union #{1 2} #{2 3}))
EOF
) || fail "vector_directive: non-zero exit ($got)"
assert_eq 'vector_directive' "$(last_line "$got")" '#{1 2 3}'

# --- (2b) vector directive with :refer ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(ns t3 [:require [clojure.set :refer [union]]])
(prn (union #{1} #{4}))
EOF
) || fail "vector_directive_refer: non-zero exit ($got)"
assert_eq 'vector_directive_refer' "$(last_line "$got")" '#{1 4}'
