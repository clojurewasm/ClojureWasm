# Task 0004: Implement basic collection types (ArrayList-based)

## Context

- Phase: 1a (Value type foundation)
- Depends on: task_0003 (Value.eql)
- References: Beta collections, PersistentList/Vector/ArrayMap/HashSet

## Plan

1. Create src/common/collections.zig with four persistent collection types
2. Add collection variants to Value tagged union
3. Extend Value.format for collection print semantics
4. Extend Value.eql for sequential/map/set equality

## Log

### 2026-02-01

- Created src/common/collections.zig with four persistent collection types:
  - PersistentList: `[]const Value` slice, count/first/rest methods
  - PersistentVector: `[]const Value` slice, count/nth methods
  - PersistentArrayMap: flat `[k1,v1,k2,v2,...]` entries, count/get (linear scan)
  - PersistentHashSet: `[]const Value` slice, count/contains (linear scan)
- All types include optional `meta: ?*const Value` for future metadata support
- Added collection variants to Value tagged union (as `*const PersistentXxx` pointers)
- Extended Value.format for Clojure print semantics: (), [], {k v, ...}, #{}
- Extended Value.eql with:
  - Sequential equality: (= '(1 2) [1 2]) => true (Clojure spec)
  - Map equality: bidirectional key-value comparison
  - Set equality: mutual containment check (order-independent)
- Helper functions: isSequential(), sequentialItems() for list/vector abstraction
- 10 new collection tests in collections.zig, 13 new tests in value.zig
- Total: ~54 tests. All passing via TDD
- Commit: 58aeed5 "Implement basic collection types with Value integration (Task 1.4)"

## Status: done
