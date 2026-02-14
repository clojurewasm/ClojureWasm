# Library Compatibility Test Results

## medley 1.8.0+

Source: https://github.com/weavejester/medley
Type: Pure Clojure utility library (.cljc)

### Results

| Metric     | Value |
|------------|------:|
| Tests      |    53 |
| Assertions |   276 |
| Pass       |   222 |
| Fail       |     5 |
| Error      |    49 |
| Pass rate  | 80.4% |

### Failure Categories

| Category              | Count | Examples                               |
|-----------------------|------:|----------------------------------------|
| Java interop methods  |    25 | .indexOf, .getMessage, .add, .size     |
| Java constructors     |    16 | java.util.ArrayList., new Exception    |
| Java static methods   |     5 | UUID/fromString, UUID/randomUUID       |
| Java class types      |     5 | PersistentQueue, java.util.UUID        |
| Missing features      |     3 | uuid? (CW UUIDs are strings)           |

### Passing Function Groups (100%)

find-first, dissoc-in, assoc-some, update-existing, update-existing-in,
map-entry, map-kv, map-keys, map-vals, map-kv-keys, map-kv-vals,
filter-kv, filter-keys, filter-vals, remove-kv, remove-keys, remove-vals,
boolean?, least, least-by, greatest, greatest-by, join, deep-merge,
mapply (partial), collate-by, index-by, interleave-all, distinct-by,
dedupe-by, take-upto, drop-upto, abs, deref-swap!, deref-reset!,
regexp?, find-in

### Failing Function Groups

| Function         | Reason                                         |
|------------------|------------------------------------------------|
| queue/queue?     | CW no PersistentQueue (instance? check fails)  |
| partition-after  | java.util.ArrayList constructor in :clj branch |
| partition-before | java.util.ArrayList constructor in :clj branch |
| partition-between| java.util.ArrayList constructor in :clj branch |
| window           | java.util.ArrayList constructor in :clj branch |
| index-of         | .indexOf Java interop method on collections    |
| ex-message       | .getMessage Java interop on exceptions          |
| ex-cause         | new Exception constructor syntax               |
| uuid/uuid?       | java.util.UUID type (CW UUIDs are strings)     |
| random-uuid      | java.util.UUID/randomUUID static method         |

### Notes

- All failures are due to Java interop that CW doesn't support
- The core map/filter/reduce utility functions work perfectly
- Reader conditionals (#? and #?@) work correctly
- defrecord works correctly (MyRecord tests pass)
- Transducer support works for non-Java-interop functions
