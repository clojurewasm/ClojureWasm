# Java Interop Pattern Mapping

Reference for test porting. Maps Java patterns to ClojureWasm equivalents.

## Type Checks

| Java Pattern              | ClojureWasm          | Notes                   |
|---------------------------|----------------------|-------------------------|
| `(instance? Long x)`     | `(integer? x)`       | CW has unified integers |
| `(instance? Double x)`   | `(float? x)`         | CW has unified floats   |
| `(instance? String x)`   | `(string? x)`        |                         |
| `(instance? Boolean x)`  | `(boolean? x)`       |                         |
| `(class x)`              | `(type x)`           |                         |

## Collections

| Java Pattern              | ClojureWasm          | Notes                     |
|---------------------------|----------------------|---------------------------|
| `(into-array xs)`         | `xs` or `(vec xs)`  | No Java arrays            |
| `(to-array xs)`           | `(vec xs)`           |                           |
| `(aset arr i v)`          | `;; CLJW-SKIP`      | No mutable arrays         |
| `(aget arr i)`            | `;; CLJW-SKIP`      | No mutable arrays         |

## Method Calls

| Java Pattern              | ClojureWasm          | Notes                     |
|---------------------------|----------------------|---------------------------|
| `(.hashCode x)`           | `(hash x)`          |                           |
| `(.equals x y)`           | `(= x y)`           |                           |
| `(.toString x)`           | `(str x)`           |                           |
| `(.length s)`             | `(count s)`         |                           |
| `(.contains coll x)`      | `(contains? coll x)`| Or `(some #{x} coll)`    |

## Numeric Casts

| Java Pattern              | ClojureWasm          | Notes                     |
|---------------------------|----------------------|---------------------------|
| `(byte x)` / `(short x)` | `(int x)`           | CW has unified integers   |
| `(long x)`                | `(int x)`           |                           |
| `(float x)` / `(double x)`| `(float x)`        | CW has unified floats     |

## Skip Patterns (Java-only)

| Java Pattern                     | Action                             |
|----------------------------------|------------------------------------|
| `(bigint x)` / `(bigdec x)`     | `;; CLJW-SKIP: no bigint/bigdec`  |
| `2/3` (ratio literal)           | `;; CLJW-SKIP: F3 no Ratio`       |
| `(new java.util.Date)`          | `;; CLJW-SKIP: JVM interop`       |
| `(java.util.ArrayList. [...])`  | `;; CLJW-SKIP: JVM interop`       |
| `(binding [*out* w] ...)`       | `;; CLJW-SKIP: F85 binding`       |
| `(import ...)`                   | `;; CLJW-SKIP: JVM interop`       |
| `proxy` / `reify` / `gen-class` | `;; CLJW-SKIP: JVM interop`       |

## Exception Mapping

| Java Pattern                             | ClojureWasm                    |
|------------------------------------------|--------------------------------|
| `(thrown? ArithmeticException ...)`      | `(thrown? Exception ...)`      |
| `(thrown? ClassCastException ...)`       | `(thrown? Exception ...)`      |
| `(thrown? IllegalArgumentException ...)` | `(thrown? Exception ...)`      |
| `(thrown? NullPointerException ...)`     | `(thrown? Exception ...)`      |
| `(thrown? UnsupportedOperationException ...)`| `(thrown? Exception ...)`  |
| `(Exception. "msg")`                    | `(Exception. "msg")` (same)   |

## Supported Interop

These Java-like patterns work in ClojureWasm:

| Pattern                  | Status    | Notes                         |
|--------------------------|-----------|-------------------------------|
| `(Exception. "msg")`    | Supported | Constructor syntax            |
| `(throw (Exception. m))`| Supported | throw + Exception constructor |
| `(try ... (catch ...))`  | Supported | try/catch/finally             |
