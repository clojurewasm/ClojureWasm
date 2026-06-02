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
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

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
(binding [*data-readers* {'foo (fn [v] (* v 2))}]
  (read-string "#foo 5"))
EOF
) || fail "case2: non-zero exit ($got)"
assert_eq 'data_readers_binding_applied' "$(last_line "$got")" '10'

# --- Case 3: *default-data-reader-fn* fallback (called with tag symbol + value) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(binding [*default-data-reader-fn* (fn [tag v] [tag v])]
  (read-string "#foo 5"))
EOF
) || fail "case3: non-zero exit ($got)"
assert_eq 'default_data_reader_fn' "$(last_line "$got")" '[foo 5]'

# --- Case 4: an entry in *data-readers* wins over *default-data-reader-fn* ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(binding [*data-readers* {'foo (fn [v] :matched)}
          *default-data-reader-fn* (fn [tag v] :defaulted)]
  (read-string "#foo 5"))
EOF
) || fail "case4: non-zero exit ($got)"
assert_eq 'readers_win_over_default' "$(last_line "$got")" ':matched'

# --- Case 5: nested tagged literals (re-entrancy: inner reads while outer reads) ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(binding [*data-readers* {'dbl (fn [v] (* v 2)) 'wrap (fn [v] {:w v})}]
  (read-string "#wrap #dbl 5"))
EOF
) || fail "case5: non-zero exit ($got)"
assert_eq 'nested_tagged_reentrant' "$(last_line "$got")" '{:w 10}'

# --- Case 6: tag applied to a collection form ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(binding [*data-readers* {'sum (fn [v] (reduce + v))}]
  (read-string "#sum [1 2 3 4]"))
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

echo "OK — phase14_tagged_literal (8 cases) green"
