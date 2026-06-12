#!/usr/bin/env bash
# test/e2e/phase14_syntax_quote_exclude.sh
#
# D-296 — syntax-quote build machinery (vec / concat / seq / list / apply /
# hash-map / hash-set) is emitted FULLY-QUALIFIED clojure.core/* so a user
# `(:refer-clojure :exclude [vec …])` cannot break syntax-quoted collection
# templates (clj parity). This was the last structural blocker for
# clojure.data.generators (ladder rung 5).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
last_line() { awk 'END { print }' <<< "$1"; }

# --- syntax-quoted [vector] / {map} / #{set} / (list) under a core-excluding ns ---
# The exclude covers the syntax-quote MACHINERY fns (vec/concat/seq/list/
# hash-map/hash-set/apply); cljw qualifies them to clojure.core/* so the
# templates below still build. (A user writing a bare excluded symbol in a
# template is a separate, correct user-ns-qualification — not tested here.)
got=$("$BIN" - <<'EOF' 2>/dev/null
(ns t (:refer-clojure :exclude [vec concat seq list hash-map hash-set apply]))
(defmacro mv [x] `[~x 1])
(defmacro mm [x] `{~x 1})
(defmacro ms [x] `#{~x})
(prn [(mv 5) (mm :k) (ms 9)])
EOF
) || fail "exclude_syntax_quote: non-zero exit ($got)"
assert_eq 'exclude_syntax_quote' "$(last_line "$got")" '[[5 1] {:k 1} #{9}]'

# --- the user can still define their own `vec` (the exclude is honored for
#     user code) while syntax-quote machinery uses clojure.core/vec ---
got=$("$BIN" - <<'EOF' 2>/dev/null
(ns t2 (:refer-clojure :exclude [vec]))
(defn vec [& _] :my-vec)
(defmacro build [x] `[~x ~x])
(prn [(vec 1 2) (build 8)])
EOF
) || fail "user_vec_plus_syntax_quote: non-zero exit ($got)"
assert_eq 'user_vec_plus_syntax_quote' "$(last_line "$got")" '[:my-vec [8 8]]'

# --- unquote-splice in a syntax-quoted vector still works ---
assert_eq 'splice_vec' "$(last_line "$("$BIN" -e '(defmacro b [x] `[~x ~@(list 2 3)]) (b 1)' 2>/dev/null)")" '[1 2 3]'
