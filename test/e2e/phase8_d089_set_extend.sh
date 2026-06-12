#!/usr/bin/env bash
# test/e2e/phase8_d089_set_extend.sh
#
# §9.10 row 8.6 cycle 4 (close cycle) — D-089 IPersistentSet -disjoin slow-path.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

assert_eq() {
    local name="$1"
    local got="$2"
    local want="$3"
    if [[ "$got" != "$want" ]]; then
        fail "$name: got '$got', want '$want'"
    fi
    echo "PASS $name -> $want"
}

last_line() {
    awk 'END { print }' <<< "$1"
}

# --- Case 1: native Tag (Long) -disjoin via outer-else slow-path ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def Long (rt/__native-type :integer))
(extend-type Long IPersistentSet (-disjoin [n k] :disjoin-on-int))
(prn (disj 42 :anything))
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'long_disj_via_extend_type' "$(last_line "$got")" ':disjoin-on-int'

# --- Case 2: builtin set disj still works ---
got=$("$BIN" -e '(disj #{:a :b :c} :a)' 2>/dev/null) || fail "case2: non-zero exit ($got)"
# Set ordering may vary; check that :a is gone and :b :c remain.
case "$(last_line "$got")" in
    "#{:b :c}"|"#{:c :b}") echo "PASS builtin_set_disj_preserved -> $(last_line "$got")" ;;
    *) fail "case2: got '$(last_line "$got")'" ;;
esac

# --- Case 3: defrecord -disjoin via IPersistentSet extend-type ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Bag [items])
(extend-type Bag IPersistentSet (-disjoin [_ k] (str "removed " k)))
(prn (disj (->Bag [1 2]) 42))
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'defrecord_disj_via_extend_type' "$(last_line "$got")" '"removed 42"'

echo "phase8_d089_set_extend: 3/3 cases pass"
