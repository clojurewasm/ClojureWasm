#!/usr/bin/env bash
# test/e2e/phase14_ns_directive.sh
#
# Phase 14 §9.16 row 14.7 — D-098 discharge. `(ns ...)` directive
# surface for `(ns foo (:refer-clojure :exclude [v1] :only [v2]))`
# and `(ns foo (:require [other :as a :refer [vs...]]))`. JVM-idiom
# `.clj` files become buildable.
#
# `:rename {old new}` is intentionally NOT landed in this cycle —
# filed as a separate follow-up debt (lower-priority and rarely
# used in Tier-A test corpora).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { tail -n 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# --- Case 1: :refer-clojure :exclude makes the excluded var unresolvable ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(ns my.app (:refer-clojure :exclude [+]))
(+ 1 2)
EOF
)
case "$diag" in
    *"Unable to resolve symbol: '+'"*|*"unresolved"*|*"name_error"*)
        echo "PASS ns_refer_clojure_exclude_blocks_resolution -> diagnostic" ;;
    *)
        fail "ns_refer_clojure_exclude_blocks_resolution: expected name_error, got '$diag'" ;;
esac

# --- Case 2: :refer-clojure :exclude allows other clojure.core vars ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(ns my.app (:refer-clojure :exclude [+]))
(prn (- 5 2))
EOF
)
assert_eq 'ns_refer_clojure_exclude_other_works' "$got" '3'

# --- Case 3: :refer-clojure :only whitelists only the named vars ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(ns my.app (:refer-clojure :only [+]))
(- 5 2)
EOF
)
case "$diag" in
    *"Unable to resolve symbol: '-'"*|*"name_error"*)
        echo "PASS ns_refer_clojure_only_blocks_other -> diagnostic" ;;
    *)
        fail "ns_refer_clojure_only_blocks_other: expected name_error for '-', got '$diag'" ;;
esac

# --- Case 4: :refer-clojure :only lets the whitelisted var through ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(ns my.app (:refer-clojure :only [+ prn]))
(prn (+ 1 2))
EOF
)
assert_eq 'ns_refer_clojure_only_whitelist_works' "$got" '3'

# --- Case 5: ns-level (:require [foo :as f]) makes alias reachable ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(ns my.app (:require [clojure.string :as s]))
(prn (s/upper-case "hi"))
EOF
)
assert_eq 'ns_require_as_alias' "$got" '"HI"'

# --- Case 6: ns-level (:require [foo :refer [bar]]) makes bar reachable ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(ns my.app (:require [clojure.string :refer [upper-case]]))
(prn (upper-case "hi"))
EOF
)
assert_eq 'ns_require_refer_names' "$got" '"HI"'

# --- Case 7: combined (:as + :refer) inside ns ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(ns my.app (:require [clojure.string :as s :refer [upper-case]]))
(prn [(s/lower-case "AB") (upper-case "cd")])
EOF
)
assert_eq 'ns_require_combined' "$got" '["ab" "CD"]'

# --- Case 8: :rename remains a clean unsupported diagnostic (D-112) ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(ns my.app (:refer-clojure :rename {+ plus}))
EOF
)
case "$diag" in
    *":rename"*"not"*"supported"*|*"feature_not_supported"*|*":rename"*)
        echo "PASS ns_rename_diagnostic_deferred -> diagnostic" ;;
    *)
        fail "ns_rename_diagnostic_deferred: expected :rename diagnostic, got '$diag'" ;;
esac

# --- Case 9: ns-unalias removes an alias; no-op (nil) on a missing one (clj parity) ---
got=$("$BIN" - <<'EOF'
(alias 's 'clojure.string)
(let [had (contains? (ns-aliases *ns*) 's)]
  (ns-unalias *ns* 's)
  (prn [had (contains? (ns-aliases *ns*) 's) (ns-unalias *ns* 'nonexistent)]))
EOF
)
assert_eq 'ns_unalias' "$got" '[true false nil]'

echo
echo "Phase 14 row 14.7 ns directive surface e2e: all green."
