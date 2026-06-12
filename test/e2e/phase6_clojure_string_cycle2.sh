#!/usr/bin/env bash
# test/e2e/phase6_clojure_string_cycle2.sh
#
# Phase 6.9 cycle 2 EXIT smoke — trim + predicate family.
#
# Adds 7 clojure.string vars on top of cycle 1's foundation:
#   trim / triml / trimr / trim-newline / starts-with? / ends-with? /
#   includes?
#
# All pure-scan over runtime/charset.zig + std.mem prefix/suffix
# helpers (UTF-8 byte-equivalent for prefix/suffix tests; codepoint-
# aware Unicode whitespace for trim family). No regex dependency.

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

# --- trim family ---

got="$("$BIN" -e '(clojure.string/trim "  hello  ")')"
assert_eq 'trim_ascii_both' "$got" '"hello"'

got="$("$BIN" -e '(clojure.string/trim "hello")')"
assert_eq 'trim_no_op' "$got" '"hello"'

got="$("$BIN" -e '(clojure.string/trim "   ")')"
assert_eq 'trim_all_ws' "$got" '""'

# Unicode ideographic space U+3000 — JVM Character/isWhitespace = true.
got="$("$BIN" -e '(clojure.string/trim "　hi　")')"
assert_eq 'trim_ideographic' "$got" '"hi"'

got="$("$BIN" -e '(clojure.string/triml "  hello  ")')"
assert_eq 'triml_left_only' "$got" '"hello  "'

got="$("$BIN" -e '(clojure.string/trimr "  hello  ")')"
assert_eq 'trimr_right_only' "$got" '"  hello"'

# trim-newline only strips trailing \r / \n (not all Unicode whitespace).
got=$("$BIN" - <<'EOF'
(prn (clojure.string/trim-newline "line
"))
EOF
)
assert_eq 'trim_newline_lf' "$got" '"line"'

got="$("$BIN" -e '(clojure.string/trim-newline "  hi  ")')"
assert_eq 'trim_newline_keeps_spaces' "$got" '"  hi  "'

# --- predicate family ---

got="$("$BIN" -e '(clojure.string/starts-with? "hello" "he")')"
assert_eq 'starts_with_true' "$got" 'true'

got="$("$BIN" -e '(clojure.string/starts-with? "hello" "lo")')"
assert_eq 'starts_with_false' "$got" 'false'

got="$("$BIN" -e '(clojure.string/starts-with? "hello" "")')"
assert_eq 'starts_with_empty_prefix' "$got" 'true'

got="$("$BIN" -e '(clojure.string/ends-with? "hello" "lo")')"
assert_eq 'ends_with_true' "$got" 'true'

got="$("$BIN" -e '(clojure.string/ends-with? "hello" "he")')"
assert_eq 'ends_with_false' "$got" 'false'

got="$("$BIN" -e '(clojure.string/includes? "hello world" "lo wo")')"
assert_eq 'includes_true' "$got" 'true'

got="$("$BIN" -e '(clojure.string/includes? "hello" "world")')"
assert_eq 'includes_false' "$got" 'false'

# Japanese substring round-trip via UTF-8 byte-equivalent prefix.
got="$("$BIN" -e '(clojure.string/includes? "あいうえお" "うえ")')"
assert_eq 'includes_utf8' "$got" 'true'

echo "phase6_clojure_string_cycle2: all 16 cases passed"
