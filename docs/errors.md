# ClojureWasm Error Catalog

Error messages organized by processing layer. Every error includes a Kind (category),
Phase (origin layer), and human-readable message.

## Error Infrastructure

**Phases** (origin of error):
- `parse` — Reader/Tokenizer
- `analysis` — Analyzer
- `macroexpand` — Macro expansion
- `eval` — VM/TreeWalk/Builtins/Interop

**Kinds** (error category):

| Kind | Label | Typical Phase | Description |
|------|-------|---------------|-------------|
| syntax_error | Syntax error | parse | Structural issues: EOF, unmatched delimiters, invalid tokens |
| number_error | Number format error | parse | Invalid numeric literals |
| string_error | String format error | parse | Invalid string/char/regex literals |
| name_error | Name error | eval | Undefined symbol, unresolved var |
| arity_error | Arity error | analysis, eval | Wrong number of arguments |
| value_error | Value error | analysis, eval | Invalid forms, duplicate keys, constraint violations |
| type_error | Type error | eval | Operation applied to wrong type |
| arithmetic_error | Arithmetic error | eval | Division by zero, overflow, range |
| index_error | Index error | eval | Out-of-bounds access |
| io_error | IO error | eval | File/network operations |
| internal_error | Internal error | eval | Implementation bug (should never reach users) |
| out_of_memory | Out of memory | eval | Allocator failure |

## Layer 1: Reader

Parses Clojure source text into Form data structures.

### Syntax Errors (25)
- EOF after `#_`, `^`, metadata, reader macro, syntax-quote, tagged literal
- EOF in reader conditional, EOF while reading collection
- Expected `(` after `#?`, Expected keyword in reader conditional
- Expected symbol after `#`, Expected symbolic value after `##`
- Invalid metadata form, Invalid regex literal, Invalid token
- Map literal must have even number of forms
- Namespaced map must be followed by a map literal
- Splice not in list
- Spliced reader conditional value must be a sequential collection
- String literal exceeds maximum size (1MB)
- Collection exceeds maximum element count (100K)
- Nesting exceeds maximum depth (1024)
- Unmatched delimiter, Unknown symbolic value

### Number Errors (4)
- Division by zero in ratio
- Invalid float/number/ratio literal

### String Errors (7)
- Invalid character literal, escape sequence, octal/unicode character
- Invalid string literal, Octal character out of range
- Unknown character name

## Layer 2: Analyzer

Transforms Forms into executable Nodes. Validates structure and bindings.

### Arity Errors (40+)
Special form argument counts:
- `def` requires 1-3 args, `if` requires 2-3, `quote` requires 1
- `throw` requires 1, `set!` requires 2, `var` requires 1
- `let`/`loop`/`for` require binding vector + body
- `fn`/`defmacro` require parameter vector
- `try` requires body, `catch` requires (catch Type name body*)
- `defprotocol`/`defrecord`/`deftype`/`reify` arg validation
- `defmulti`/`defmethod` arg validation

### Value Errors (60+)
Binding and destructuring validation:
- `&` must be followed by a binding
- `:as`/`:keys`/`:strs`/`:syms` validation
- Binding pattern must be symbol/vector/map
- Can't let qualified name
- Duplicate map keys, even-count binding vectors
- Map destructuring key/value validation
- Method arglist/name must be specific types
- Expression nesting exceeds maximum depth (1024)
- Macro expansion failures

### Syntax Errors (13)
- Unable to resolve var
- `case*` internal form validation
- `set!` target must be a symbol
- `var` requires namespace/symbol/environment

## Layer 3: Compiler

Compiles Nodes to bytecode. No direct error generation — errors propagate
from Analyzer or are caught as internal errors.

## Layer 4: VM

Executes bytecode. Most errors originate in builtins called during execution.

### Direct VM Errors
- StackOverflow (stack exceeds 32K values or 1024 frames)
- InvalidInstruction (jump out of bounds, invalid catch IP)
- Undefined variable resolution failures

## Layer 5: TreeWalk

Direct AST evaluation. Parallel to VM with same error semantics.

### Direct TreeWalk Errors
- StackOverflow (call depth exceeds 512)
- Undefined variable resolution failures

## Layer 6: Builtins

Runtime function implementations. Largest error surface (~600 unique messages).

### Arity Errors (355)
Standard pattern: `"Wrong number of args ({d}) passed to {function}"`

### Type Errors (319)
Standard patterns:
- `"{operation} expects {type}, got {s}"`
- `"Cannot cast {s} to {type}"`

### Arithmetic Errors (45)
- Divide by zero
- Bit index out of range [0, 63]
- Integer overflow
- Range step must not be zero
- Value out of Unicode range
- Repeat count / rand-int arg must be non-negative/positive
- Cannot rationalize NaN or Infinity

### Index Errors (21)
- nth index out of bounds for array/string/vector/list
- assoc/subvec index out of bounds
- String index out of range

### IO Errors (27)
- Could not open/read/delete file
- Could not locate on load path
- Could not create parent directories
- EOF while reading
- Namespace not found after loading file
- HTTP request failures

### Value Errors (30)
- Can't dynamically bind non-dynamic var
- Can't pop empty list/vector
- Format width/precision exceeds maximum (10K)
- str output exceeds maximum size (10MB)
- Input source stack overflow/underflow
- ChunkBuffer already consumed

## Layer 7: Interop

Java interop shims for CW-native classes.

### Supported Classes
URI, File, UUID, PushbackReader, StringBuilder, StringWriter, BufferedWriter

### Error Patterns (74)
- Constructor/method arity validation
- Type validation for arguments
- `"No matching method {s} for {class}"` — method not found
- `"Unknown class: {s}"` — class not found
- IO errors for reader/writer operations
- Invalid instance state (closed writer, consumed buffer)

## Resource Limits

| Resource | Limit | Location |
|----------|-------|----------|
| Reader nesting depth | 1,024 | reader.zig |
| Reader string size | 1 MB | reader.zig |
| Reader collection count | 100,000 | reader.zig |
| Analyzer recursion depth | 1,024 | analyzer.zig |
| VM stack | 32,768 values | vm.zig |
| VM call frames | 1,024 | vm.zig |
| VM exception handlers | 16 | vm.zig |
| TreeWalk call depth | 512 | tree_walk.zig |
| TreeWalk local vars | 256 | tree_walk.zig |
| Format width/precision | 10,000 | misc.zig |
| str output | 10 MB | strings.zig |
| repeat count | 1,000,000 | sequences.zig |
| Regex recursion | 10,000 | matcher.zig |
| File read | 10 MB | main.zig |
