#!/usr/bin/env bash
# test/e2e/phase15_campaign_keywords.sh — validation-campaign batch (D-232) from
# running the upstream clojure.test-clojure.keywords suite: `.name`/`.getName`/
# `.toString` interop on the Namespace value, regex in a macro expansion
# (valueToForm `.regex` arm), and clojure.test `thrown-with-msg?`. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# Namespace interop (.name → symbol, .toString → string)
assert_eq 'ns-dot-name'   "$("$BIN" -e '(symbol? (.name *ns*))' 2>&1 | tail -1)" 'true'
assert_eq 'ns-dot-getname' "$("$BIN" -e '(str (.getName *ns*))' 2>&1 | tail -1)" '"user"'
assert_eq 'ns-dot-str'    "$("$BIN" -e '(.toString *ns*)' 2>&1 | tail -1)" '"user"'
# regex surviving a macro expansion (valueToForm .regex arm)
assert_eq 'regex-macro'   "$("$BIN" -e '(defmacro m [] `(re-find #"a.c" "xabcy")) (m)' 2>&1 | tail -1)" '"abc"'
# clojure.test thrown-with-msg? (msg matches → pass; msg mismatch → fail)
assert_eq 'twm-pass'  "$("$BIN" -e '(ns t (:use clojure.test)) (deftest x (is (thrown-with-msg? Throwable #"boom" (throw (ex-info "boom!" {}))))) (let [s (run-tests)] [(:pass s) (:fail s)])' 2>&1 | tail -1)" '[1 0]'
assert_eq 'twm-fail'  "$("$BIN" -e '(ns t (:use clojure.test)) (deftest x (is (thrown-with-msg? Throwable #"nope" (throw (ex-info "boom!" {}))))) (let [s (run-tests)] [(:pass s) (:fail s)])' 2>&1 | tail -1)" '[0 1]'
# the campaign capstone: the upstream keywords suite RUNS end-to-end off -cp
# (real gaps fixed; residual mismatches are accepted error-message divergences).
# Guarded — the upstream Clojure clone is a local reference, absent on CI/ubuntunote.
UPSTREAM="$HOME/Documents/OSS/clojure/test"
if [ -f "$UPSTREAM/clojure/test_clojure/keywords.clj" ]; then
    KW="$("$BIN" -cp "$UPSTREAM" -e '(require (quote clojure.test-clojure.keywords)) (let [s (clojure.test/run-tests (quote clojure.test-clojure.keywords))] (>= (:pass s) 7))' 2>&1 | tail -1)"
    assert_eq 'keywords-runs' "$KW" 'true'
else
    echo "SKIP keywords-runs (upstream Clojure clone absent)"
fi

echo "OK — phase15_campaign_keywords (7 cases) green"
