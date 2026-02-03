# T14.1: clojure.test/deftest, is, testing 移植

## Goal

Implement the minimal clojure.test framework providing deftest, is, and testing macros.
This enables writing tests in the standard Clojure style.

## Background

- SCI tests use an inline test framework in core_test.clj
- The inline framework already provides working deftest/is/testing
- Goal is to extract this into a proper clojure.test namespace

## Design Decisions

- **No new Zig builtins needed** — all required primitives exist (atom, swap!, defmacro, etc.)
- **Keep it simple** — based on existing inline framework, not full clojure.test
- **Namespace approach** — load via bootstrap.zig like core.clj

## Plan

1. Create src/clj/clojure/test.clj with minimal framework:
   - Test registry (atom of test descriptors)
   - Result counters (pass/fail/error atoms)
   - Context stack for testing nesting
   - deftest, is, testing macros
   - run-tests function

2. Modify bootstrap.zig:
   - Add @embedFile for clojure/test.clj
   - Add loadTest function (similar to loadCore)
   - Call loadTest after loadCore in initialization

3. Update SCI core_test.clj:
   - Remove inline framework (lines 11-76)
   - Add (require 'clojure.test) or rely on auto-refer
   - Verify all 72 tests still pass

4. Verify with zig build test

## Implementation Notes

- clojure.test vars should be in clojure.test namespace
- User code should be able to (require '[clojure.test :refer [deftest is testing run-tests]])
- For simplicity, we'll auto-refer these into user namespace (like core.clj)

## Log

1. Created src/clj/clojure/test.clj with minimal test framework:
   - test-registry, pass-count, fail-count, error-count, testing-contexts atoms
   - join-str, do-report-pass, do-report-fail, do-is, push-context, pop-context, do-testing, register-test helpers
   - deftest, is, testing macros
   - run-tests function

2. Modified bootstrap.zig:
   - Added @embedFile for clojure/test.clj
   - Added loadTest function (creates clojure.test namespace, refers clojure.core, evaluates test.clj)
   - loadTest re-refers all clojure.test bindings into user namespace

3. Updated main.zig and nrepl.zig to call loadTest after loadCore

4. Updated SCI core_test.clj:
   - Removed inline test framework (lines 11-76)
   - Now uses clojure.test auto-referred from bootstrap

5. Issues encountered:
   - ^:private metadata not supported on def -> removed ^:private
   - defn- with docstrings not supported (fn special form doesn't parse docstrings) -> used inline comments
   - VM backend fails on SCI tests but TreeWalk works -> deferred to separate issue

6. Results:
   - clojure.test loads successfully
   - SCI tests: 72/72 pass, 267 assertions (TreeWalk)
   - VM backend issue to be investigated separately
