#!/usr/bin/env bash
# test/e2e/phase9_edn_read_string.sh
#
# §9.11 row 9.2 — clojure.edn/read-string smoke.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# --- Case 1: integer ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "42"))
EOF
) || fail "case1: non-zero exit ($got)"
assert_eq 'edn_read_int' "$(last_line "$got")" '42'

# --- Case 2: vector ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "[1 2 3]"))
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'edn_read_vector' "$(last_line "$got")" '[1 2 3]'

# --- Case 3: map ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "{:a 1 :b 2}"))
EOF
) || fail "case3: non-zero exit ($got)"
case "$(last_line "$got")" in
    "{:a 1, :b 2}"|"{:b 2, :a 1}") echo "PASS edn_read_map -> $(last_line "$got")" ;;
    *) fail "case3: got '$(last_line "$got")'" ;;
esac

# --- Case 4: set ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "#{:a :b}"))
EOF
) || fail "case4: non-zero exit ($got)"
case "$(last_line "$got")" in
    "#{:a :b}"|"#{:b :a}") echo "PASS edn_read_set -> $(last_line "$got")" ;;
    *) fail "case4: got '$(last_line "$got")'" ;;
esac

# --- Case 5: list (NOT evaluated) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "(+ 1 2)"))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'edn_read_list' "$(last_line "$got")" '(+ 1 2)'

# --- Case 6: keyword ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string ":foo/bar"))
EOF
) || fail "case6: non-zero exit ($got)"
assert_eq 'edn_read_keyword' "$(last_line "$got")" ':foo/bar'

# --- Case 7: nil ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "nil"))
EOF
) || fail "case7: non-zero exit ($got)"
assert_eq 'edn_read_nil' "$(last_line "$got")" 'nil'

# --- Case 8: empty / whitespace-only / comment-only => nil for edn. clj's
# clojure.edn/read-string 1-arity defaults {:eof nil}, so it returns nil
# ("Returns nil when s is nil or empty" per its docstring); core/read-string
# THROWS on the same input — they differ on exactly this. D-581 corrected the
# earlier D-269 reading that made edn throw too. :eof opt still overrides. ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string ""))
EOF
) || fail "case8: non-zero exit ($got)"
assert_eq 'edn_read_empty_nil' "$(last_line "$got")" 'nil'
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "   "))
EOF
) || fail "case8ws: non-zero exit ($got)"
assert_eq 'edn_read_ws_nil' "$(last_line "$got")" 'nil'
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "; comment only"))
EOF
) || fail "case8c: non-zero exit ($got)"
assert_eq 'edn_read_comment_nil' "$(last_line "$got")" 'nil'
# `:eof` sentinel returns the given value instead of nil.
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string {:eof :none} ""))
EOF
) || fail "case8b: non-zero exit ($got)"
assert_eq 'edn_read_eof_opt' "$(last_line "$got")" ':none'
# JVM: one-arity defaults to nil at EOF; two-arity without :eof THROWS,
# even when the source contains only a comment or a discarded form.
for source in '""' '"; comment"' '"#_1"'; do
    assert_eq 'edn_one_arg_eof' "$($BIN -e "(clojure.edn/read-string $source)")" 'nil'
    if out=$($BIN -e "(clojure.edn/read-string {} $source)" 2>&1); then
        fail "edn_two_arg_eof: unexpectedly accepted $source ($out)"
    fi
    case "$out" in *EOF*|*eof*) echo "PASS edn_two_arg_eof -> error" ;; *) fail "edn_two_arg_eof: $out" ;; esac
done
assert_eq 'edn_discard_then_value' "$($BIN -e '(clojure.edn/read-string {} "#_1 2")')" '2'
# Neither nil nor an arbitrary scalar is an options map on the JVM.
for opts in nil 42; do
    if out=$($BIN -e "(clojure.edn/read-string $opts \"1\")" 2>&1); then
        fail "edn_invalid_opts: unexpectedly accepted $opts ($out)"
    fi
    echo 'PASS edn_invalid_opts -> error'
done

# --- Case 9: nested ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string "[1 {:a 2} #{:x}]"))
EOF
) || fail "case9: non-zero exit ($got)"
assert_eq 'edn_read_nested' "$(last_line "$got")" '[1 {:a 2} #{:x}]'

echo "phase9_edn_read_string: 9/9 cases pass"
