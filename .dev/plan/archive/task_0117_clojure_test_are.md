# T14.2: clojure.test/are, run-tests 移植

## Goal

Add `are` macro to clojure.test for template-based test assertions.

## Background

- `are` macro uses `clojure.template/do-template` for template expansion
- `do-template` requires `clojure.walk/postwalk-replace`
- Current status: `walk`, `postwalk`, `postwalk-replace` are all todo in vars.yaml

## Dependencies

1. `clojure.walk/walk` — basic tree traversal
2. `clojure.walk/postwalk` — depth-first post-order traversal
3. `clojure.walk/postwalk-replace` — symbol replacement in expressions
4. `clojure.template/apply-template` — single template application
5. `clojure.template/do-template` — repeated template expansion

## Plan

1. Implement `walk` function in core.clj (or clojure/walk.clj)
   - Handle list, vector, map, set, seq types
   - Recursive structure traversal

2. Implement `postwalk` and `postwalk-replace`
   - Build on walk function

3. Implement `apply-template` and `do-template`
   - Can add to core.clj or create clojure/template.clj

4. Implement `are` macro in clojure/test.clj
   - Uses do-template with is assertion

5. Test with example:
   ```clojure
   (are [x y] (= x y)
     2 (+ 1 1)
     4 (* 2 2))
   ```

## Alternative: Simplified are

If walk implementation is too complex, consider a simplified `are` that:

- Only works with simple expressions (no nested structure)
- Uses zipmap + direct symbol replacement

## Log

1. Implemented walk, postwalk, prewalk, postwalk-replace, prewalk-replace in core.clj
   - Simplified version without metadata support
   - Handles list, vector, map, set, seq types

2. Implemented apply-template and do-template in core.clj
   - Uses postwalk-replace for template expansion

3. Implemented `are` macro in clojure/test.clj
   - Uses postwalk-replace and zipmap for template expansion
   - Works with arbitrary expressions: (are [x y] (= x y) 2 (+ 1 1) 4 (\* 2 2))

4. Updated vars.yaml:
   - clojure.walk: walk, postwalk, prewalk, postwalk-replace, prewalk-replace -> done
   - clojure.template: apply-template, do-template -> done
   - clojure.test: are, deftest, is, testing, run-tests -> done

5. All tests pass:
   - SCI tests: 72/72 pass, 267 assertions (TreeWalk)
   - Zig tests: all pass
