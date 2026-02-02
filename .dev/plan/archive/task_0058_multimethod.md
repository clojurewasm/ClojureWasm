# T7.4: Multimethod — defmulti, defmethod

## Goal

Implement Clojure multimethods: defmulti and defmethod.

## Components

1. **Value**: Add MultiFn struct + value variant
2. **Node**: Add defmulti_node, defmethod_node variants
3. **Analyzer**: Add special form handlers for defmulti, defmethod
4. **TreeWalk**: Add runDefmulti, runDefmethod, callMultiFn
5. **Bootstrap**: Integration tests

## Plan (TDD)

1. Red: Test `(defmulti area :shape) (defmethod area :circle [x] 1) (area {:shape :circle})` => 1
2. Green: Implement all components
3. Refactor

## Design

MultiFn = { name, dispatch_fn, methods_map, default_key }
Dispatch: eval args -> call dispatch_fn on args -> lookup method by result -> call method

## Log

- Starting T7.4
- Added MultiFn struct to value.zig, multi_fn variant to Value union (done in prev session)
- Fixed exhaustive switches across codebase (predicates.zig, macro.zig, main.zig, tree_walk.zig)
- Added DefMultiNode/DefMethodNode to node.zig
- Added analyzeDefmulti/analyzeDefmethod to analyzer.zig special_forms table
- Added runDefmulti/runDefmethod/callMultiFn to tree_walk.zig
- Added keyword dispatch to callValue (keywords as dispatch functions)
- Added defmulti/defmethod_node to compiler.zig (InvalidNode for now)
- Two bootstrap tests pass: basic dispatch + default method
- All 662 tests green
- T7.4 complete
