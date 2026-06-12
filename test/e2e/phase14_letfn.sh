#!/usr/bin/env bash
# test/e2e/phase14_letfn.sh
#
# D-201 — `letfn` / the `letfn*` special form. Unlike `let*` (sequential,
# a body cannot forward-reference a later binding), `letfn*` pre-binds ALL
# fn names before analysing any body, so the bound fns are mutually
# recursive. cljw closures snapshot captured slots BY VALUE, so `letfn*`
# allocates every closure, then patches each closure's captured letfn slots
# with the real sibling fns (a one-time local patch — cljw keeps the fast
# snapshot model rather than JVM/SCI by-reference cells).
#
# Macro: `(letfn [(f [..] ..) (g [..] ..)] body)` →
#        `(letfn* [f (fn [..] ..) g (fn [..] ..)] body)`.

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

# --- Case 1: a single letfn binding, called from the body ---
got=$("$BIN" -e '(letfn [(f [x] (+ x 10))] (f 5))') || fail "case1 exit ($got)"
assert_eq 'single_binding' "$(last_line "$got")" '15'

# --- Case 2: self-recursion (the fn calls itself via its letfn slot) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (letfn [(fact [n] (if (= n 0) 1 (* n (fact (dec n)))))]
  (fact 5)))
EOF
) || fail "case2 exit ($got)"
assert_eq 'self_recursion' "$(last_line "$got")" '120'

# --- Case 3: mutual recursion (even?/odd? cross-reference each other) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (letfn [(my-even? [n] (if (= n 0) true (my-odd? (dec n))))
        (my-odd? [n] (if (= n 0) false (my-even? (dec n))))]
  [(my-even? 10) (my-odd? 7)]))
EOF
) || fail "case3 exit ($got)"
assert_eq 'mutual_recursion' "$(last_line "$got")" '[true true]'

# --- Case 4: a letfn fn closes over an enclosing let* local ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (let [base 100]
  (letfn [(add-base [x] (+ base x))]
    (add-base 23))))
EOF
) || fail "case4 exit ($got)"
assert_eq 'closes_over_outer' "$(last_line "$got")" '123'

# --- Case 5: a multi-arity letfn fn ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (letfn [(g ([x] (g x 1))
           ([x y] (+ x y)))]
  [(g 5) (g 5 20)]))
EOF
) || fail "case5 exit ($got)"
assert_eq 'multi_arity' "$(last_line "$got")" '[6 25]'

# --- Case 6: both backends agree (dual-backend parity) ---
got=$("$BIN" --compare - <<'EOF' 2>/dev/null
(letfn [(my-even? [n] (if (= n 0) true (my-odd? (dec n))))
        (my-odd? [n] (if (= n 0) false (my-even? (dec n))))]
  (my-even? 8))
EOF
) || fail "case6 exit ($got)"
assert_eq 'backend_parity' "$(last_line "$got")" 'OK true'

echo "OK — phase14_letfn (6 cases) green"
