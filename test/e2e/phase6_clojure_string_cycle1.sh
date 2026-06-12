#!/usr/bin/env bash
# test/e2e/phase6_clojure_string_cycle1.sh
#
# ADR-0032 + Phase 6.9 cycle-1 EXIT smoke.
#
# Proves the multi-file bootstrap loader + (in-ns 'foo.bar) primitive
# + clojure.string namespace surface (cycle-1 trio: upper-case /
# lower-case / blank?).
#
# Cycle 2-4 follow-ups: trim family, predicate family, replace,
# split (per private/notes/phase6-6.9-survey.md §6).

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

# 1. upper-case ASCII.
got="$("$BIN" -e '(clojure.string/upper-case "hi")')"
assert_eq 'upper_case_ascii' "$got" '"HI"'

# 2. lower-case ASCII.
got="$("$BIN" -e '(clojure.string/lower-case "HI")')"
assert_eq 'lower_case_ascii' "$got" '"hi"'

# 3. upper-case mixed.
got="$("$BIN" -e '(clojure.string/upper-case "Hello World")')"
assert_eq 'upper_case_mixed' "$got" '"HELLO WORLD"'

# 4. blank? on empty string.
got="$("$BIN" -e '(clojure.string/blank? "")')"
assert_eq 'blank_empty' "$got" 'true'

# 5. blank? on whitespace-only string (ASCII spaces).
got="$("$BIN" -e '(clojure.string/blank? "   ")')"
assert_eq 'blank_ascii_ws' "$got" 'true'

# 6. blank? on non-blank string.
got="$("$BIN" -e '(clojure.string/blank? "hi")')"
assert_eq 'blank_non_blank' "$got" 'false'

# 7. blank? on nil.
got="$("$BIN" -e '(clojure.string/blank? nil)')"
assert_eq 'blank_nil' "$got" 'true'

# 8. blank? on tab + newline (other whitespace categories).
got="$("$BIN" -e '(clojure.string/blank? "
")')"
assert_eq 'blank_tab_newline' "$got" 'true'

# 9. (in-ns) round-trip — switch + define + resolve qualified.
#    Multi-form via stdin: each top-level form analyse-then-evals, so
#    `(in-ns 'my.ns)` evaluates before `(def x 42)` is analysed; the
#    `my.ns/x` lookup at the end sees a populated namespace. The
#    `do`-wrapped variant doesn't work because Clojure analyses every
#    subform of a single top-level form upfront — same on JVM.
got=$("$BIN" - <<'EOF' | tail -1
(in-ns (quote my.ns))
(def x 42)
(in-ns (quote user))
(prn my.ns/x)
EOF
)
assert_eq 'in_ns_round_trip' "$got" '42'

echo "phase6_clojure_string_cycle1: all 9 cases passed"
