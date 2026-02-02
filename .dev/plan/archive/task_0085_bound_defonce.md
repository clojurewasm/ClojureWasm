# T9.5.5: bound? builtin + defonce

## Problem

No way to check if a Var has been defined. defonce macro needs bound? to
avoid re-evaluating def'd forms.

## Analysis

Clojure's bound? takes Var objects: (bound? #'x). We don't have Var as a
Value type yet. Pragmatic approach: implement bound? as a builtin that
checks if a symbol resolves to a Var with a non-nil root in the current
namespace.

However, this means bound? takes a symbol, not a Var. defonce can use this:
(defmacro defonce [name expr]
`(when-not (bound? '~name) (def ~name ~expr)))

Note: quote the symbol to prevent evaluation.

Alternative: add a has-root? flag to Var (since nil is a valid binding).
For now, we use a simpler approach — check if Var exists in namespace.

## Plan

1. RED: Test bound? on defined vs undefined symbols
2. GREEN: Implement bound? in predicates.zig (resolve symbol in Env)
3. RED: Test defonce macro in core.clj
4. GREEN: Add defonce to core.clj
5. REFACTOR

## Complications

bound? needs access to Env to resolve symbols. BuiltinFn has no Env context.
Options:

- (a) Module-level env pointer (like atom.call_fn) — simplest
- (b) Make bound? a special form in analyzer — overkill
- (c) Implement via core.clj using resolve — but resolve also needs Env

Going with (a): add env pointer to predicates module.

Actually, simpler: bound? can work at the TreeWalk level by checking if
the var exists in the namespace. But the builtin doesn't have Env...

Best approach: implement `bound?` using the same module-level env pattern.
bootstrap.zig already sets macro_eval_env. We can read it from a shared
module.

## Log

- RED: Test bound? on undefined/defined symbols + defonce — confirmed failures
- GREEN: Added bound? builtin in predicates.zig with current_env module-level Env pointer.
  Set in bootstrap.setupMacroEnv. Added defonce macro to core.clj.
  Updated builtin count tests (predicates 24->25, registry 105->106).
- All tests pass including defonce idempotency test.
