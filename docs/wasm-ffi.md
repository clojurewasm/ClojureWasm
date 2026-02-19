# Wasm FFI Reference

CW can load and call WebAssembly modules via the `cljw.wasm` namespace.
This is a unique feature — no other Clojure implementation provides Wasm FFI.

## Quick Start

```clojure
(require '[cljw.wasm :as wasm])

;; Load a .wasm module
(def mod (wasm/load "math.wasm"))

;; Create a typed wrapper for a Wasm function
(def add (wasm/fn mod "add" {:params [:i32 :i32] :results [:i32]}))

;; Call it like any Clojure function
(add 3 4)  ; => 7
(map #(add % 10) [1 2 3])  ; => (11 12 13)
```

## Loading Modules

### wasm/load

```clojure
(wasm/load path)
(wasm/load path opts)
```

Loads a `.wasm` binary file and returns a module instance.

**Options map**:
- `:imports` — map of import namespace to function map (for host functions)

```clojure
;; Simple load
(def mod (wasm/load "module.wasm"))

;; Load with host function imports
(def mod (wasm/load "module.wasm"
           {:imports {"env" {"log" (fn [x] (println "wasm:" x))
                             "add" (fn [a b] (+ a b))}}}))
```

### wasm/validate

```clojure
(wasm/validate path)  ; => true or throws
```

Validates a `.wasm` binary without instantiating.

### wasm/instantiate

```clojure
(wasm/instantiate path)
(wasm/instantiate path opts)
```

Lower-level module instantiation (same as `load`).

## Calling Functions

### wasm/fn

```clojure
(wasm/fn module name signature)
```

Creates a callable Clojure function that wraps a Wasm export.

**Signature map**:
- `:params` — vector of parameter types
- `:results` — vector of return types

**Wasm types**: `:i32`, `:i64`, `:f32`, `:f64`

```clojure
(def add (wasm/fn mod "add" {:params [:i32 :i32] :results [:i32]}))
(add 3 4)  ; => 7

;; Void function (no return)
(def init (wasm/fn mod "init" {:params [] :results []}))
(init)

;; Multiple params
(def compute (wasm/fn mod "compute"
               {:params [:i32 :i32 :f64] :results [:f64]}))
```

### wasm/fn-ref

```clojure
(wasm/fn-ref module name signature)
```

Returns a reference to a Wasm function without creating a wrapper.
Used for passing functions as table entries or callbacks.

## Memory Operations

### wasm/memory-size

```clojure
(wasm/memory-size module)  ; => size in pages (64KB each)
```

### wasm/memory-read

```clojure
(wasm/memory-read module offset length)  ; => byte string
```

Reads `length` bytes from linear memory starting at `offset`.

### wasm/memory-write

```clojure
(wasm/memory-write module offset data)
```

Writes byte string `data` to linear memory starting at `offset`.

### wasm/memory-read-string / memory-write-string

```clojure
(wasm/memory-read-string module offset length)  ; => UTF-8 string
(wasm/memory-write-string module offset string)
```

String-specific variants with UTF-8 encoding.

```clojure
;; Write a string to Wasm memory, read it back
(wasm/memory-write mod 256 "Hello, Wasm!")
(wasm/memory-read mod 256 12)  ; => "Hello, Wasm!"

;; Unicode support
(wasm/memory-write mod 512 "こんにちは")
(wasm/memory-read mod 512 15)  ; => "こんにちは"
```

## Globals

### wasm/global

```clojure
(wasm/global module name)  ; => current value
```

### wasm/global-set

```clojure
(wasm/global-set module name value)
```

## Tables

### wasm/table

```clojure
(wasm/table module name)  ; => table info
```

## Host Functions

### wasm/host-fn

```clojure
(wasm/host-fn f signature)
```

Wraps a Clojure function for use as a Wasm import.

### wasm/host-memory

```clojure
(wasm/host-memory module)
```

Returns a reference to the module's linear memory.

## Module Inspection

### wasm/exports

```clojure
(wasm/exports module)  ; => map of export names to types
```

### wasm/module-info

```clojure
(wasm/module-info module)  ; => module metadata
```

## Host Function Callbacks

Wasm modules can call back into Clojure via host functions:

```clojure
;; Define host functions
(def log-atom (atom []))

(def mod (wasm/load "module.wasm"
           {:imports {"env" {"print_i32" (fn [n] (swap! log-atom conj n))
                             "print_str" (fn [off len]
                                           (wasm/memory-read mod off len))}}}))

;; Wasm calls back into Clojure
(def compute (wasm/fn mod "compute_and_print"
               {:params [:i32 :i32] :results []}))
(compute 10 20)
@log-atom  ; => [30]
```

## Type Mapping

| Wasm Type | Clojure Type | Notes |
|-----------|-------------|-------|
| `i32` | long | 32-bit integer, sign-extended to 64-bit |
| `i64` | long | 64-bit integer |
| `f32` | double | 32-bit float, widened to 64-bit |
| `f64` | double | 64-bit float |

## Error Handling

Wasm traps (e.g., out-of-bounds memory access, integer divide by zero)
are caught and reported as CW runtime errors:

```clojure
;; Wasm trap: integer divide by zero
;; Wasm trap: out of bounds memory access
;; Wasm trap: unreachable
```

## Wasm Engine

CW uses [zwasm](https://github.com/clojurewasm/zwasm) v1.1.0 as its Wasm runtime:
- WebAssembly 2.0 (100% spec compliance, 62K tests)
- ARM64 and x86_64 JIT compilation
- WASI preview1 support
