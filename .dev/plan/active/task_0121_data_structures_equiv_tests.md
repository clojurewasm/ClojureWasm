# T14.10: data_structures.clj Equivalent Tests

## Goal

Create equivalent tests for test/clojure/test_clojure/data_structures.clj.
Reference source: 1364 lines, heavily Java-dependent.

## Analysis

### Sections to include (Java-free or adaptable)

| Section                       | Lines     | Notes                                               |
| ----------------------------- | --------- | --------------------------------------------------- |
| test-equality                 | 131-217   | Exclude lazy-seq/into-array/Object/ratio            |
| test-count                    | 221-266   | Exclude Queue/into-array/ArrayList/HashMap          |
| test-conj                     | 269-344   | Exclude exception tests                             |
| test-peek                     | 349-379   | Exclude exception tests                             |
| test-pop                      | 382-414   | Exclude exception tests                             |
| test-list                     | 419-459   | Exclude ratio                                       |
| test-find                     | 464-478   | Fully portable                                      |
| test-contains?                | 481-570   | Exclude Java collections/into-array/exception tests |
| test-keys                     | 573-599   | Exclude sorted-map/meta tests                       |
| test-vals                     | 602-628   | Exclude sorted-map/meta tests                       |
| test-key                      | 647-662   | Exclude ratio                                       |
| test-val                      | 665-680   | Exclude ratio                                       |
| test-get                      | 682-711   | Exclude exception tests                             |
| test-nested-map-destructuring | 713-724   | Fully portable                                      |
| test-hash-set                 | 738-786   | Exclude Integer/Long equality                       |
| test-set                      | 891-936   | Exclude into-array                                  |
| test-disj                     | 939-994   | Exclude exception tests                             |
| test-assoc                    | 1098-1106 | Exclude exception tests                             |

### Sections to exclude

- Generative tests (defspec) — lines 28-126
- sorted-set, sorted-set-by, sorted-map tests — sorted collections not fully supported
- PersistentQueue tests — Queue not implemented
- defrecord/defstruct tests — not implemented
- Hash collection tests (mix-collection-hash) — unchecked-\* not implemented
- Java interop tests throughout

## Plan

1. Create test/clojure_test/data_structures.clj
2. Add tests section by section:
   - Equality (collections, not lazy-seq)
   - Count (basic collections)
   - Conj (list, vector, map, set)
   - Peek (list, vector)
   - Pop (list, vector)
   - List (creation, nesting)
   - Find (map lookup)
   - Contains? (map, set, vector index)
   - Keys/Vals (basic map operations)
   - Key/Val (MapEntry access)
   - Get/Get-in (map access)
   - Nested map destructuring
   - Hash-set (creation, equality)
   - Set (conversion)
   - Disj (set removal)
   - Assoc (map/vector)
3. Run tests, fix any failures
4. Update vars.yaml if new functions discovered
5. Update checklist.md if deferred items found

## Exclusions (F## tracking)

- F52: sorted-set, sorted-set-by, sorted-map-by — not implemented
- F40/F41: set/string sequences — already tracked
- F53: PersistentQueue — not implemented
- F54: defrecord, defstruct — not implemented

## Log
