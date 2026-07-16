#!/usr/bin/env bash
# test/e2e/phase14_static_member_diagnostics.sh
#
# ADR-0174 D3 — a resolved host class + missing static member is a precise
# member-level diagnostic, never the misleading "No namespace: 'System'"
# (the pre-0174 fall-through). Position-split like clj: a bare
# `Class/member` symbol (value position / 1.12 method-value attempt) and a
# `(Class/member …)` call head render member-shaped errors naming the
# class's JVM FQCN. The clojure.lang.* deferred-rewrite path (AD-008) is
# NOT affected: an unmodeled clojure.lang member still analyzes (loads) and
# only errors when evaluated.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_contains() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == *"$want"* ]] || fail "$name: got '$got', want substring '$want'"
    echo "PASS $name"
}
assert_not_contains() {
    local name="$1" got="$2" bad="$3"
    [[ "$got" != *"$bad"* ]] || fail "$name: output contains forbidden '$bad': $got"
    echo "PASS $name"
}

# `|| true`: most probes exit non-zero by design (they assert on the error
# text); without it `set -e` kills the script at the first substitution.
err() { "$BIN" -e "$1" 2>&1 || true; }

# --- call position: member miss on a resolved class ---
# (System/console is a permanently-skipped member — the OPAQUE story: it
# renders this diagnostic instead of ever being half-implemented.)
got=$(err '(System/console)')
assert_contains     'call_member_msg'   "$got" "No matching static method: console in class java.lang.System"
assert_not_contains 'call_no_namespace' "$got" "No namespace"

got=$(err '(java.time.Instant/nonexistent 1 2)')
assert_contains 'call_with_args' "$got" "No matching static method: nonexistent in class java.time.Instant"

# --- value position: bare Class/member symbol ---
got=$(err 'System/out2')
assert_contains     'value_member_msg'   "$got" "No such static member: out2 in class java.lang.System"
assert_not_contains 'value_no_namespace' "$got" "No namespace"

got=$(err 'Math/PI2')
assert_contains 'value_bare_class' "$got" "No such static member: PI2 in class java.lang.Math"

# --- a genuine unknown namespace still says No namespace ---
got=$(err '(totally.unknown.Ns/foo 1)')
assert_contains 'real_ns_miss' "$got" "No namespace"

# --- clojure.lang.* deferred rewrite unaffected (AD-008): analyzes, loads,
#     errors only when evaluated ---
got=$(err '(defn f [] (clojure.lang.RT/baseLoader)) :loaded')
assert_contains 'deferred_loads' "$got" ":loaded"
got=$(err '((fn [] (clojure.lang.RT/baseLoader)))')
assert_contains 'deferred_evals_loud' "$got" "not supported"

echo "ALL PASS"
