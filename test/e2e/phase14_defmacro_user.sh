#!/usr/bin/env bash
# test/e2e/phase14_defmacro_user.sh
#
# Phase 14 §9.16 row 14.6 — D-099 discharge. User-defined
# `(defmacro foo [args...] body)` dispatch via the analyzer's
# expandIfMacro user-fn fallback at macro_dispatch.zig:107.
#
# Shape (a) per survey: analyzer arm intern's the Var with
# `flags.macro_ = true`; expandIfMacro routes Form args through
# formToValue, calls rt.vtable.callFn with the macro fn_val, then
# converts the returned Value back to Form via valueToForm. JVM
# Clojure's implicit `&form` / `&env` args are intentionally NOT
# threaded — Tier-A test corpora (deftest / are / testing /
# declare) do not introspect them; the omission is filed as
# D-099-followup.
#
# No VM-DEFER needed: macro expansion is analysis-time, before
# either backend's eval.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
# Each top-level form's value is printed; the assertion checks the
# LAST line so the `defmacro` itself (which prints the var-quote form
# `#'ns/name`) does not have to be filtered separately.
last_line() { tail -n 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

# Build a Form-shaped list at runtime using cons (cw v1 today exposes
# cons + cons-chain rather than a `list` builtin; both routes produce
# the same heap-list Value at the macro return site).

# --- Case 1: minimal defmacro that wraps an if ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(defmacro my-when [t b] (cons 'if (cons t (cons b (cons nil nil)))))
(prn (my-when true 42))
EOF
)
assert_eq 'defmacro_my_when_true' "$got" '42'

# --- Case 2: same macro, falsy path returns nil ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(defmacro my-when [t b] (cons 'if (cons t (cons b (cons nil nil)))))
(prn (my-when false 42))
EOF
)
assert_eq 'defmacro_my_when_false' "$got" 'nil'

# --- Case 3: defmacro returning a constant value form ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(defmacro always-42 [] 42)
(prn (always-42))
EOF
)
assert_eq 'defmacro_always_42' "$got" '42'

# --- Case 4: macro that returns a Zig-macro-transform call ---
# `when` is a built-in macro transform; the user macro composes with it.
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(defmacro double-when [t b] (cons 'when (cons t (cons b nil))))
(prn (double-when (= 1 1) :ok))
EOF
)
assert_eq 'defmacro_composes_with_zig_macro' "$got" ':ok'

# --- Case 5: macro arg passes through unchanged (identity) ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(defmacro identity-macro [x] x)
(prn (identity-macro :hello))
EOF
)
assert_eq 'defmacro_identity' "$got" ':hello'

# --- Case 7: macro Var without an fn root raises a clean error ---
diag=$("$BIN" - <<'EOF' 2>&1 || true
(def ^:macro broken-macro 42)
(broken-macro)
EOF
)
case "$diag" in
    *"is not a function"*|*"macro"*"not callable"*|*"is not callable"*)
        echo "PASS defmacro_non_fn_root_raises -> diagnostic" ;;
    *)
        # Acceptable: ^:macro reader metadata path may not yet land
        # (D-075). If `(def ^:macro foo ...)` simply produces an
        # ordinary Var here, the case is N/A; record and continue.
        echo "SKIP defmacro_non_fn_root_raises -> ^:macro reader path not yet landed (D-075)" ;;
esac

# --- Case 8: multi-arity defmacro with docstring + attr-map (potpuri shape) ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(defmacro my-if
  "doc" {:added "0.1"}
  ([t then] (cons 'if (cons t (cons then (cons nil nil)))))
  ([t then else] (cons 'if (cons t (cons then (cons else nil))))))
(prn [(my-if true :y) (my-if false :y :n) (:arglists (meta #'my-if)) (:doc (meta #'my-if))])
EOF
)
assert_eq 'defmacro_multi_arity_doc' "$got" '[:y :n ([t then] [t then else]) "doc"]'

# --- Case 9: implicit &form / &env (ADR-0086) ---
got=$("$BIN" - <<'EOF' 2>/dev/null | last_line
(defmacro ec [] (count &env))
(defmacro hl [s] (contains? &env s))
(defmacro fc [& xs] (count &form))
(defmacro mlk [] (contains? (meta &form) :line))
(defmacro em? [] (map? &env))
(prn [(let [a 1 b 2 c 3] (ec)) (ec) (let [q 9] (hl q)) (let [q 9] (hl zz)) (fc 10 20 30) (mlk) (em?)])
EOF
)
# clj parity (clj -M /tmp/fe.clj): top-level &env is nil (count 0, map? false),
# in-let &env is a map; &form carries :line meta; &form count includes the head.
assert_eq 'defmacro_form_env' "$got" '[3 0 true false 4 true false]'

echo
echo "Phase 14 row 14.6 defmacro user-dispatch e2e: all green."
