#!/usr/bin/env bash
# test/e2e/macro_throw_catchable.sh — a macro that THROWS while expanding must
# surface the exception it threw, catchable and with its message intact.
#
# Argument validation in a macro is ordinary Clojure — clojure.core's own
# `assert-args` does it, and so does every macro that rejects a malformed
# binding vector. cljw used to fold such a throw into
# "Internal error: macro callFn raised foreign error": the message was lost,
# the class was lost, and no `catch` could see it, so a macro could not tell
# its caller what was wrong with the call. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

# `-e` echoes each form's value, so the printed line is second-to-last.
line() { "$BIN" -e "$1" 2>&1 | tail -2 | sed -n 1p; }

# --- a macro throwing ex-info, expanded through eval -------------------------
P='(defmacro m [] (throw (ex-info "boom" {:a 1})))
   (println (try (eval (quote (m))) :no-throw (catch Throwable e (str "caught:" (ex-message e)))))'
assert_eq 'ex-info-message' "$(line "$P")" 'caught:boom'

# The ex-data survives the crossing too.
P='(defmacro m [] (throw (ex-info "boom" {:a 1})))
   (println (try (eval (quote (m))) :no-throw (catch Throwable e (:a (ex-data e)))))'
assert_eq 'ex-data' "$(line "$P")" '1'

# --- a macro throwing a host exception class, caught BY that class -----------
P='(defmacro m [] (throw (IllegalArgumentException. "bad args")))
   (println (try (eval (quote (m))) :no-throw (catch IllegalArgumentException e (str "iae:" (ex-message e)))))'
assert_eq 'host-class-catch' "$(line "$P")" 'iae:bad args'

# --- expanded directly at the call site, with no eval in between -------------
# A lexically-enclosing `try` does NOT catch this, in cljw or in clj: the form
# is macroexpanded while the whole top-level form is being compiled, which is
# before the try's runtime exists. Verified against the clj oracle, which
# likewise reports "Syntax error macroexpanding m …" and does not catch. What
# must hold is that the macro's own message reaches the user.
P='(defmacro m [] (throw (ex-info "direct" {})))
   (println (try (m) :no-throw (catch Throwable e (str "caught:" (ex-message e)))))'
out="$("$BIN" -e "$P" 2>&1 || true)"
[[ "$out" == *"direct"* ]] || fail "direct-expansion: message lost from '$out'"
[[ "$out" != *"Internal error"* ]] || fail "direct-expansion: reported as an internal error: '$out'"
echo "PASS direct-expansion (uncaught at compile time, message intact)"

# --- a validating macro of the shape clojure.core's assert-args has ----------
P='(defmacro my-let [bindings & body]
     (when-not (even? (count bindings))
       (throw (IllegalArgumentException. "my-let requires an even number of forms")))
     (cons (quote let) (cons bindings body)))
   (println (try (eval (quote (my-let [a 1 b] a)))
              :no-throw (catch Throwable e (str "caught:" (ex-message e)))))'
assert_eq 'validating-macro' "$(line "$P")" 'caught:my-let requires an even number of forms'

# --- a macro that does NOT throw is unaffected -------------------------------
P='(defmacro m [x] (list (quote inc) x)) (println (m 41))'
assert_eq 'non-throwing-macro' "$(line "$P")" '42'

echo "OK macro_throw_catchable"
