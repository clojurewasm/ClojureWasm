# Task 3.14: Remaining core macros in core.clj

## Goal

Add essential Clojure macros to core.clj, evaluated at bootstrap time.
Focus on macros that are Form->Form transformations (no runtime support needed).

## Scope

Priority 1 (this task):

- `cond` — multi-branch conditional
- `if-not` — negated if
- `when-not` — negated when
- `if-let` — binding + conditional
- `when-let` — binding + when
- `->` — thread-first
- `->>` — thread-last
- `and` — short-circuit logical and
- `or` — short-circuit logical or
- `defn-` — private defn
- `comment` — evaluates to nil
- `doto` — object chaining
- `dotimes` — N-iteration loop
- `identity` — identity function
- `comp` — function composition (2-arity)
- `partial` — partial application
- `complement` — predicate negation
- `constantly` — constant function

## Dependencies

- T3.10 (core.clj bootstrap) — completed
- T3.13 (HOFs) — completed

## Plan

All macros are defined as `(defmacro ...)` in core.clj.
Utility functions use `(defn ...)`.

Each macro is added one at a time with a bootstrap test in bootstrap.zig.

## Log

### Macros added to core.clj

- `comment` — evaluates to nil
- `cond` — multi-branch conditional (recursive)
- `if-not` — negated if
- `when-not` — negated when
- `->` — thread-first (recursive)
- `->>` — thread-last (recursive)
- `and` — short-circuit logical and (recursive)
- `or` — short-circuit logical or (recursive)
- `defn-` — private defn (no private flag yet)
- `dotimes` — N-iteration loop

### Functions added to core.clj

- `identity` — returns its argument
- `constantly` — returns a fn that always returns x
- `complement` — returns negation of predicate

### Builtins added

- `vector` — creates vector from args (needed for syntax-quote expansion)
- `hash-map` — creates map from key-value pairs (needed for syntax-quote expansion)

### Tests

- bootstrap.zig: comment, cond, if-not, when-not, and/or, identity/constantly/complement, thread-first, thread-last, defn-, dotimes
- All 464+ tests pass
