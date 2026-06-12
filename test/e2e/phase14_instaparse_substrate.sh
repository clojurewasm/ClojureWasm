#!/usr/bin/env bash
# test/e2e/phase14_instaparse_substrate.sh — the instaparse substrate batch:
# bindable *out*/*err* (D-238 second half), IObj/IMeta native membership
# (ADR-0134 value-driven slice), and Character/codePointAt + Character/toChars.
# All expected values oracle-verified against clj 2026-06-13, EXCEPT the
# documented divergence: `(instance? IObj (range 3))` is false on cljw (clj:
# true) because cljw limits IObj to the tags where with-meta WORKS today
# (interface_membership.zig IOBJ_TAGS doc comment).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

got=$("$BIN" - <<'EOF' 2>/dev/null
(prn [(instance? clojure.lang.IObj [1]) (instance? clojure.lang.IObj 'sym) (instance? clojure.lang.IObj (map inc [1])) (instance? clojure.lang.IObj "s") (instance? clojure.lang.IObj 5) (instance? clojure.lang.IObj :k) (instance? clojure.lang.IObj (range 3))])
(prn [(instance? clojure.lang.IMeta (atom 1)) (instance? clojure.lang.IMeta #'prn) (instance? clojure.lang.IMeta {:a 1}) (instance? clojure.lang.IMeta 5)])
EOF
) || true
want='[true true true false false false false]
[true true true false]'
assert_eq 'iobj_imeta_membership' "$got" "$want"

# *out* rebinding routes print/println through the bound writer value
# (java.io.StringWriter here; instaparse's print-method Failure does
# `(binding [*out* w] …)` with the print-method writer handle).
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn (let [w (java.io.StringWriter.)] (binding [*out* w] (print "hi") (println " x")) (str w)))
(prn (let [w (java.io.StringWriter.)] (binding [*out* w] (pr {:a 1})) (str w)))
(println "direct-stdout-still-works")
EOF
) || true
want='"hi x\n"
"{:a 1}"
direct-stdout-still-works'
assert_eq 'out_var_rebinding' "$got" "$want"

# Character statics: codePointAt (string codepoint indexing incl. non-ASCII)
# + toChars (1-element char array; cljw chars ARE codepoints).
got=$("$BIN" - <<'EOF' 2>/dev/null
(prn [(Character/codePointAt "abc" 1) (vec (Character/toChars 97)) (Character/codePointAt "あい" 1)])
EOF
) || true
assert_eq 'character_codepoint_statics' "$got" '[98 [\a] 12356]'

echo "OK — phase14_instaparse_substrate (3 cases) green"
