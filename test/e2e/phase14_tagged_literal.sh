#!/usr/bin/env bash
# test/e2e/phase14_tagged_literal.sh
#
# D-200 / ADR-0073 — EDN reader tagged-literal infra + data readers.
# `#tag form` reads to a `.tagged` Form; `formToValue` applies the data
# reader found in `*data-readers*` (the dynamic Var, so a `(binding …)`
# frame is honoured), else `*default-data-reader-fn*`, else raises
# "No reader function for tag …" (clj parity — NOT a placeholder value).
#
# The `#uuid`/`#inst` value-type wiring is a SEPARATE later ADR; the root
# `*data-readers*` table ships EMPTY, so an unbound tag raises. This file
# exercises the reusable infra via runtime-bound readers.
#
# Verified via e2e top-level forms (NOT the clj_diff batch sweep, which
# wraps each line in (prn …) and cannot host top-level (binding …)).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() {
    echo "FAIL $1" >&2
    exit 1
}

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" != "$want" ]]; then
        fail "$name: got '$got', want '$want'"
    fi
    echo "PASS $name -> $want"
}

last_line() { awk 'END { print }' <<< "$1"; }

# --- Case 1: unknown tag raises "No reader function for tag <t>" (clj parity) ---
if out=$("$BIN" -e '(read-string "#foo 5")' 2>&1); then
    fail "case1: expected non-zero exit, got success ($out)"
fi
case "$out" in
    *"No reader function for tag foo"*) echo "PASS unknown_tag_raises -> (clj-parity error)" ;;
    *) fail "case1: wrong error: $out" ;;
esac

# --- Case 2: a runtime-bound *data-readers* reader is applied (eval-time read) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (binding [*data-readers* {'foo (fn [v] (* v 2))}]
  (read-string "#foo 5")))
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'data_readers_binding_applied' "$(last_line "$got")" '10'

# --- Case 3: *default-data-reader-fn* fallback (called with tag symbol + value) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (binding [*default-data-reader-fn* (fn [tag v] [tag v])]
  (read-string "#foo 5")))
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'default_data_reader_fn' "$(last_line "$got")" '[foo 5]'

# --- Case 4: an entry in *data-readers* wins over *default-data-reader-fn* ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (binding [*data-readers* {'foo (fn [v] :matched)}
          *default-data-reader-fn* (fn [tag v] :defaulted)]
  (read-string "#foo 5")))
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'readers_win_over_default' "$(last_line "$got")" ':matched'

# --- Case 5: nested tagged literals (re-entrancy: inner reads while outer reads) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (binding [*data-readers* {'dbl (fn [v] (* v 2)) 'wrap (fn [v] {:w v})}]
  (read-string "#wrap #dbl 5")))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'nested_tagged_reentrant' "$(last_line "$got")" '{:w 10}'

# --- Case 6: tag applied to a collection form ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (binding [*data-readers* {'sum (fn [v] (reduce + v))}]
  (read-string "#sum [1 2 3 4]")))
EOF
) || fail "case6: non-zero exit ($got)"
assert_eq 'tag_over_collection' "$(last_line "$got")" '10'

# --- Case 7: expression-position #tag resolves at read/analyze time, NOT a
#     runtime binding (clj: the form is read before the binding takes effect).
#     With an empty global table the tag is unbound → raises. ---
if out=$("$BIN" - <<'EOF' 2>&1
(binding [*data-readers* {'foo (fn [v] v)}] #foo 5)
EOF
); then
    fail "case7: expected non-zero exit (expr-pos uses read-time table), got: $out"
fi
case "$out" in
    *"No reader function for tag foo"*) echo "PASS expr_pos_uses_read_time_table -> (clj-parity error)" ;;
    *) fail "case7: wrong error: $out" ;;
esac

# --- Case 8: both backends agree (dual-backend parity) ---
got=$("$BIN" --compare - <<'EOF' 2>/dev/null
(binding [*data-readers* {'foo (fn [v] (* v v))}]
  (read-string "#foo 9"))
EOF
) || fail "case8: non-zero exit ($got)"
assert_eq 'backend_parity' "$(last_line "$got")" 'OK 81'

# --- Case 9: clojure.edn/read-string 2-arity :readers (opts is the FIRST arg) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string {:readers {'foo (fn [v] (* v 2))}} "#foo 5"))
EOF
) || fail "case9: non-zero exit ($got)"
assert_eq 'edn_2arity_readers' "$(last_line "$got")" '10'

# --- Case 10: 2-arity :default fn (called with tag symbol + value) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string {:default (fn [tag v] [tag v])} "#foo 5"))
EOF
) || fail "case10: non-zero exit ($got)"
assert_eq 'edn_2arity_default' "$(last_line "$got")" '[foo 5]'

# --- Case 11: 2-arity :eof returned on empty input ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (clojure.edn/read-string {:eof :the-end} ""))
EOF
) || fail "case11: non-zero exit ($got)"
assert_eq 'edn_2arity_eof' "$(last_line "$got")" ':the-end'

# --- Case 12: 1-arity still reads a plain form (no opts) ---
got=$("$BIN" -e '(clojure.edn/read-string "3")' 2>/dev/null) || fail "case12: non-zero exit ($got)"
assert_eq 'edn_1arity_plain' "$(last_line "$got")" '3'

# --- Case 13: 2-arity with no matching reader still raises (empty :readers) ---
if out=$("$BIN" -e '(clojure.edn/read-string {} "#foo 5")' 2>&1); then
    fail "case13: expected non-zero exit, got success ($out)"
fi
case "$out" in
    *"No reader function for tag foo"*) echo "PASS edn_2arity_unknown_raises -> (clj-parity error)" ;;
    *) fail "case13: wrong error: $out" ;;
esac

# --- Case 14 (ADR-0075): tagged-literal constructor + tagged-literal? ---
assert_eq 'tagged_literal_pred' "$("$BIN" -e "(tagged-literal? (tagged-literal 'foo 5))")" 'true'
assert_eq 'tagged_literal_pred_neg' "$("$BIN" -e '(tagged-literal? 5)')" 'false'

# --- Case 15: ILookup :tag / :form (ILookup-only, other keys → nil) ---
assert_eq 'tagged_literal_tag'  "$("$BIN" -e "(:tag (tagged-literal 'foo 5))")" 'foo'
assert_eq 'tagged_literal_form' "$("$BIN" -e "(:form (tagged-literal 'foo 5))")" '5'
assert_eq 'tagged_literal_other_nil' "$("$BIN" -e "(:nope (tagged-literal 'foo 5))")" 'nil'
assert_eq 'tagged_literal_get' "$("$BIN" -e "(get (tagged-literal 'foo 5) :form)")" '5'

# --- Case 16: pr-str is `#tag form` (EDN round-trip shape; prefix probe to
#     avoid the stdin-mode trailing-nil from println) ---
assert_eq 'tagged_literal_pr_str' "$("$BIN" -e "(pr-str (tagged-literal 'foo 5))")" '"#foo 5"'

# --- Case 17: = by (tag, form) ---
assert_eq 'tagged_literal_eq' "$("$BIN" -e "(= (tagged-literal 'foo 5) (tagged-literal 'foo 5))")" 'true'
assert_eq 'tagged_literal_neq' "$("$BIN" -e "(= (tagged-literal 'foo 5) (tagged-literal 'bar 5))")" 'false'

# --- Case 18: *default-data-reader-fn* = tagged-literal carries unknown tags
#     (opt-in; the default still RAISES — ADR-0073 contract unchanged) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (binding [*default-data-reader-fn* tagged-literal]
  (tagged-literal? (read-string "#unknown 42"))))
EOF
) || fail "case18: non-zero exit ($got)"
assert_eq 'default_fn_carries_unknown' "$(awk 'END{print}' <<< "$got")" 'true'

# --- Case 19 (regression): a TaggedLiteral works as a map KEY / set element.
#     hash + `=` alone miss — the HAMT's rt-free keyEqValue needs the arm. ---
assert_eq 'tagged_literal_map_key' "$("$BIN" -e "(get {(tagged-literal 'foo 5) :v} (tagged-literal 'foo 5))")" ':v'
assert_eq 'tagged_literal_set_elem' "$("$BIN" -e "(contains? #{(tagged-literal 'foo 5)} (tagged-literal 'foo 5))")" 'true'

echo "OK — phase14_tagged_literal (20 cases) green"
