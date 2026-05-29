#!/usr/bin/env bash
# test/e2e/phase8_d089_seq_extend.sh
#
# §9.10 row 8.6 cycle 1 — D-089 retro-audit ISeq family + -empty on IPC.
# Wires outer-else slow-paths for `first` / `rest` / `next` / `empty`
# so user `(extend-type X ISeq (-first [c] …))` etc. become functional
# for non-builtin receivers. Mirrors the row 7.7 pattern for
# `count` / `seq` / `conj` / `reduce`.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

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

# --- Case 1: defrecord reaches first via ISeq extend-type ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Box [v])
(extend-type Box ISeq (-first [b] (get b :v)))
(first (->Box 42))
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'defrecord_first_via_extend_type' "$(last_line "$got")" '42'

# --- Case 2: defrecord reaches rest via ISeq extend-type ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Box [v])
(extend-type Box ISeq (-rest [b] '(99)))
(rest (->Box 42))
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'defrecord_rest_via_extend_type' "$(last_line "$got")" '(99)'

# --- Case 3: defrecord reaches next via ISeq extend-type ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Box [v])
(extend-type Box ISeq (-next [b] (get b :v)))
(next (->Box "hi"))
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'defrecord_next_via_extend_type' "$(last_line "$got")" '"hi"'

# --- Case 4: defrecord reaches empty via IPC -empty extend-type ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(defrecord Box [v])
(extend-type Box IPersistentCollection (-empty [_] :empty-box))
(empty (->Box 42))
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'defrecord_empty_via_extend_type' "$(last_line "$got")" ':empty-box'

# --- Case 5: native Tag (Long) reaches first via outer-else slow-path ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(def Long (rt/__native-type :integer))
(extend-type Long ISeq (-first [n] (+ n 100)))
(first 42)
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'long_first_via_outer_else_slow_path' "$(last_line "$got")" '142'

# --- Case 6: next on builtin coll (vector) returns rest behaviour ---
got=$("$BIN" -e '(next [1 2 3])' 2>/dev/null) || fail "case6: non-zero exit ($got)"
assert_eq 'next_on_vector_returns_rest' "$(last_line "$got")" '(2 3)'

# --- Case 7: next on singleton returns nil (JVM next-returns-nil contract) ---
got=$("$BIN" -e '(next [1])' 2>/dev/null) || fail "case7: non-zero exit ($got)"
assert_eq 'next_on_singleton_returns_nil' "$(last_line "$got")" 'nil'

# --- Case 8: next on nil returns nil ---
got=$("$BIN" -e '(next nil)' 2>/dev/null) || fail "case8: non-zero exit ($got)"
assert_eq 'next_on_nil_returns_nil' "$(last_line "$got")" 'nil'

echo "phase8_d089_seq_extend: 8/8 cases pass"
