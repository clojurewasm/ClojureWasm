#!/usr/bin/env bash
# test/e2e/phase14_def_meta_quote_value.sh
#
# D-316 — def-target metadata MAP VALUES are evaluated for the realistic
# (quoted-datum) case. clj evaluates `^{:k expr}` / attr-map values at def
# time; the idiomatic non-self-evaluating value is a quoted datum
# (`:arglists '([k v])`, `{:k '(a b)}`). A `(quote X)` meta value lifts to X,
# matching clj. (Arbitrary computed meta like `{:k (+ 1 2)}` needs def-time
# runtime eval — the narrow D-316 residual, not covered here.)
#
# Forms contain `'` (quote), so use heredoc stdin (cljw_invocation rule B).

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

# defn attr-map with a quoted-list value → lifts to the unquoted datum.
got=$("$BIN" - <<'EOF' 2>/dev/null | tail -1
(defn g {:foo '(a b)} [x] x)
(prn (:foo (meta (var g))))
EOF
)
assert_eq 'defn_quoted_list_meta' "$got" '(a b)'

# defmulti attr-map :arglists '([k v]) → ([k v]) (the integrant case).
got=$("$BIN" - <<'EOF' 2>/dev/null | tail -1
(defmulti mm {:arglists '([k v])} (fn [k v] k))
(prn (:arglists (meta (var mm))))
EOF
)
assert_eq 'defmulti_quoted_arglists' "$got" '([k v])'

# raw def with reader ^{:tag '(x y)} → (x y).
got=$("$BIN" - <<'EOF' 2>/dev/null | tail -1
(def ^{:tag '(x y)} z 1)
(prn (:tag (meta (var z))))
EOF
)
assert_eq 'def_reader_quoted_meta' "$got" '(x y)'

# literal (self-evaluating) meta values are unchanged.
got=$("$BIN" - <<'EOF' 2>/dev/null | tail -1
(defn h {:foo :bar} [x] x)
(prn (:foo (meta (var h))))
EOF
)
assert_eq 'defn_literal_meta' "$got" ':bar'

# defn's synthesized :arglists stays a list of param vectors (not quote-wrapped).
got=$("$BIN" - <<'EOF' 2>/dev/null | tail -1
(defn k [x y] x)
(prn (:arglists (meta (var k))))
EOF
)
assert_eq 'defn_synth_arglists' "$got" '([x y])'

echo "ALL PASS phase14_def_meta_quote_value"
