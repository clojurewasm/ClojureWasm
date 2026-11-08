# C FFI: call a shared library from cljw

`cljw.ffi` opens a shared library with `dlopen` and turns a C symbol into an
ordinary Clojure fn. No libffi, no binding generator, no rebuild of cljw.

```clojure
(require '[cljw.ffi :as ffi])

(def libm (ffi/open "libm.so.6"))
(def pow (ffi/function libm "pow" [:double :double] :double))
(pow 2.0 10.0)   ;=> 1024.0
(map pow [2 3] [3 2])   ;=> (8.0 9.0)
```

| fn | does |
|---|---|
| `(open path)` | library handle; absolute, relative or bare soname |
| `(close lib)` | nil, idempotent; its functions then throw `{:ffi/error :closed}` |
| `(sym lib name)` | symbol address as an integer |
| `(function lib name arg-types ret-type)` | a Clojure fn; types resolved once |
| `(call lib name arg-types ret-type & args)` | one-shot call |
| `(string ptr)` | copy a NUL-terminated C string; 0 or nil gives nil |
| `(bytes ptr n)` | copy `n` bytes into a byte array |

| type | C side | Clojure side |
|---|---|---|
| `:void` | `void` (return only) | nil |
| `:int` | `int` | integer, truncated to 32 bits; a return is sign-extended |
| `:long` | `int64_t` / `long` | integer |
| `:double` | `double` | float, or an integer widened |
| `:pointer` | `T *` | an address integer, nil (NULL), or a primitive array: its storage, no copy, C reads and writes it in place for the call |
| `:string` | `const char *` | a copy both ways; NULL is nil; a returned string is never freed |
| `:bytes` | `const uint8_t *` | argument only: a copy of a byte array (one memcpy), so C writes do not reach it |

A primitive array is contiguous native storage of its element width, so it is
a C array as it stands:

| constructor | C element |
|---|---|
| `byte-array` | `int8_t` |
| `short-array` | `int16_t` |
| `int-array` | `int32_t` |
| `long-array` | `int64_t` |
| `float-array` | `float` |
| `double-array` | `double` |
| `char-array` | `uint32_t` (a code point) |
| `boolean-array` | `uint8_t` (0 or 1) |

```clojure
(def dot (ffi/function lib "dot" [:pointer :pointer :long] :double))
(dot (double-array xs) (double-array ys) (count xs))
```

`object-array`, `to-array` and `into-array` hold Clojure values and are not
accepted as `:pointer`.

Limits: at most 6 integer-class and 8 `:double` arguments, no varargs
(`printf`), no structs by value, no `float`. Available on x86_64 and aarch64,
Linux and macOS; absent on wasm targets (`-Dffi=false` drops it from a build).
Failures are `ex-info` with `{:ffi/error :open|:symbol|:signature|:arity|:arg-type|:closed}`.

The same API ships in clojurust as `clojure.rust.ffi`, so a portable adapter
is one reader conditional:

```clojure
(:require #?(:cljw [cljw.ffi :as ffi] :rust [clojure.rust.ffi :as ffi]))
```

## The hive C ABI

[`hive_call.clj`](./hive_call.clj) drives any library that exports
`hive_call(op, json) -> char*` and `hive_free`: a Go c-shared, Rust cdylib,
C or Zig library alike.

```sh
cljw -M docs/examples/ffi/hive_call.clj /path/to/libvectorcraft.so ops
# {:ok true, :value [{:doc "Execute an engine command ...", :name "engine.execute", ...} ...]}
```
