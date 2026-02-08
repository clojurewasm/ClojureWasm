# F121: Cross-Language Benchmark Equivalence Fixes

Audit date: 2026-02-08. Source: automated code equivalence audit of all 25 benchmarks.
13 benchmarks OK, 7 have cross-language equivalence issues, 5 are Clojure-only.

## Critical (algorithm mismatch)

### 09_sieve — Different algorithms

| Language | Algorithm                        | Complexity     |
|----------|----------------------------------|----------------|
| Clojure  | Functional filter-based sieve    | ~O(n^2)        |
| C        | Standard Sieve of Eratosthenes   | O(n log log n) |
| Python   | Standard Sieve of Eratosthenes   | O(n log log n) |
| Ruby     | Standard Sieve of Eratosthenes   | O(n log log n) |

**Fix options**:
- A) Change C/Python/Ruby to functional filter-based sieve (match Clojure)
- B) Change Clojure to mutable-array sieve (loses "idiomatic Clojure" aspect)
- C) Document as "idiomatic comparison" not "algorithm comparison"

**Recommendation**: (A) — the point is to compare language runtimes, not algorithms.

### 07_map_ops — C uses plain array, not hash map

| Language | Data structure               |
|----------|------------------------------|
| Clojure  | Persistent hash map (HAMT)   |
| Zig      | AutoHashMap                  |
| Java     | HashMap                      |
| C        | `calloc` plain array         |
| Python   | dict                         |
| Ruby     | Hash                         |

C does array[i] access instead of hash lookup — orders of magnitude less work.

**Fix**: Replace C implementation with a real hash map (e.g., khash or simple open-addressing).

## High (semantic mismatch)

### 15_keyword_lookup — struct field vs hash lookup

| Language | Operation                        |
|----------|----------------------------------|
| Clojure  | Hash map keyword lookup          |
| C/Zig    | Struct member access (offset)    |
| Java     | HashMap.get("score")             |
| Python   | dict["score"]                    |

C/Zig struct access is pointer+offset, not hash computation.

**Fix**: Change C/Zig to use hash map (or rename benchmark to "field-access").

### 12_gc_stress — allocation asymmetry

| Language | Allocation                           |
|----------|--------------------------------------|
| Clojure  | Keyword hash map (3 entries + intern)|
| C        | malloc simple 3-field struct         |
| Zig      | GPA create Node struct               |
| Java     | HashMap with 3 String entries        |

Clojure does keyword interning + hash computation per map; C does a single malloc.

**Fix**: Either simplify Clojure to use vector/list, or make C use a hash-map-like structure.

### 17_nested_update — persistent vs mutable

| Language | Operation                            |
|----------|--------------------------------------|
| Clojure  | `update-in` (n persistent map copies)|
| C        | `m.a.b.c++` (in-place mutation)      |

Clojure allocates new maps each iteration; C modifies a single struct.

**Fix**: Change C to copy-on-write style, or accept as "idiomatic" comparison.

## Medium (minor asymmetry)

### 05_map_filter_reduce — list construction order

Clojure builds list with `cons` (reversed), then map/filter/reduce.
C/Zig/Java build array 0→n-1 in order.

Algorithmic complexity is the same (O(n)) but memory access patterns differ.

**Fix**: Minor — could normalize construction order but impact is small.

### 08_list_build — Python uses deque

| Language | Data structure        |
|----------|-----------------------|
| Clojure  | Cons list (prepend)   |
| C/Zig    | Linked list (prepend) |
| Java     | LinkedList (prepend)  |
| Python   | `collections.deque`   |

Python's deque is array-backed, not a linked list.

**Fix**: Change Python to use a simple class-based linked list.

## OK (no issues)

01_fib_recursive, 02_fib_loop, 03_tak, 04_arith_loop, 06_vector_ops,
10_nqueens, 18_string_ops

## Clojure-only (no cross-language comparison)

11_atom_swap, 13_lazy_chain, 14_transduce, 16_protocol_dispatch,
19_multimethod_dispatch, 20_real_workload, 21-25_wasm_*

## Suggested priority

1. 07_map_ops (C array → hash map) — easiest fix, most misleading
2. 09_sieve (align algorithms) — most impactful on reported results
3. 15_keyword_lookup (C struct → hash map) — semantic mismatch
4. 08_list_build (Python deque → linked list) — easy fix
5. 12_gc_stress, 17_nested_update — harder to fix fairly
6. 05_map_filter_reduce — low priority, minor impact
