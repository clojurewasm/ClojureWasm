#!/usr/bin/env bash
# test/e2e/data_errors_catchable.sh
#
# A rejection caused by BAD DATA must be catchable.
#
# cljw's `not_implemented` Kind is deliberately uncatchable, so that an
# unsupported feature cannot be quietly swallowed by a `(catch Throwable …)`.
# That is right for an unsupported feature and wrong for bad input: a program
# that parses untrusted JSON, or calls a function with an argument of the wrong
# type, must be able to handle the rejection — JVM Clojure throws a catchable
# exception in every case below, so a `(try … (catch Throwable …))` that works
# on clj must work here.
#
# Found on the ClojureWasm playground: /api/eval answered 500 to a malformed
# request body, because the handler's `(catch Throwable _ …)` could not fire —
# `cljw.json/decode` raised `not_implemented` for a JSON syntax error.
#
# Each case below was verified against the `clj` oracle to be `:caught` there.
# To find more candidates, list the uncatchable raise sites and ask of each
# whether it rejects a FEATURE or a VALUE:
#
#     grep -rn 'raise(\.feature_not_supported' src/
#
# `enumeration-seq` / `iterator-seq` are the counter-example: cljw has no Java
# Enumeration, so those genuinely are unsupported features and stay uncatchable.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { awk 'END { print }' <<< "$1"; }

# catchable <name> <expr> — the expr must raise, and the raise must be caught.
catchable() {
    local name="$1" expr="$2" got
    got=$("$BIN" - <<EOF 2>/dev/null
(require '[clojure.string] '[clojure.walk] '[clojure.data.json])
(prn (try $expr :NOT-RAISED (catch Throwable _ :caught)))
EOF
) || fail "$name: non-zero exit (the raise escaped the catch)"
    [[ "$(last_line "$got")" == ':caught' ]] \
        || fail "$name: got '$(last_line "$got")', want ':caught'"
    echo "PASS $name"
}

# Bad data handed to a JSON codec.
catchable json_read_malformed   '(clojure.data.json/read-str "not json")'
catchable json_read_truncated   '(clojure.data.json/read-str "{\"a\": }")'
catchable json_write_unencodable '(clojure.data.json/write-str (fn [x] x))'

# Wrong-typed argument — clj raises ClassCastException for each of these.
catchable deliver_non_promise   '(deliver 42 1)'
catchable escape_non_map_non_fn '(clojure.string/escape "a" 5)'
catchable walk_non_fn_callback  '(clojure.walk/postwalk 5 {:a 1})'

# 2026-08-05 sweep: the whole remaining population was classified (grep the
# recipe above). Malformed FORM SHAPES — libspecs, destructuring directives,
# import specs, reader conditionals — became the catchable `form_malformed`
# (clj: CompilerException, catchable); wrong-typed runtime args became
# type/value errors; EDN parse errors mirror the JSON fix. Representative
# cases, each verified :CAUGHT on the clj oracle:
catchable edn_read_malformed    '(clojure.edn/read-string "#bad")'
catchable require_non_libspec   '(require 123)'
catchable out_bound_non_writer  '(binding [*out* 5] (println :x))'
catchable eval_malformed_ns     "(eval '(ns))"
catchable eval_bad_destructure  "(eval '(let [{:bad 1} {}] 1))"
catchable read_string_bad_cond  '(read-string "#?[")'
catchable substring_oob         '(.substring "abc" 1 99)'

# Multi-key dissoc on a non-map receiver folds over single-key `-without`, and the
# first dispatch raises a catchable protocol-no-impl (clj: ClassCastException on the
# String->IPersistentMap cast). Was the uncatchable `feature_not_supported` — the
# process died straight through `(catch Throwable …)`.
catchable dissoc_multikey_nonmap  '(dissoc "string" \s \t)'
catchable dissoc_multikey_apply   '(apply dissoc "string" [\s \t])'

# The counter-example: a genuinely unsupported feature stays UNCATCHABLE, so
# `(catch Throwable …)` must NOT swallow it. Asserted by the inverse: the
# process exits non-zero and the catch does not produce a value.
got=$("$BIN" - <<'EOF' 2>&1 || true
(prn (try (enumeration-seq nil) :NOT-RAISED (catch Throwable _ :caught)))
EOF
)
grep -q 'is not supported in ClojureWasm' <<< "$got" \
    || fail "unsupported_stays_uncatchable: expected an uncaught unsupported-feature error, got '$got'"
# Match the printed VALUE, not any line mentioning it: the error report echoes
# the offending source line, which itself contains the `:caught` literal.
grep -qx ':caught' <<< "$got" \
    && fail "unsupported_stays_uncatchable: a catch swallowed an unsupported feature"
echo "PASS unsupported_stays_uncatchable"

echo "data_errors_catchable: 16/16 cases pass"
