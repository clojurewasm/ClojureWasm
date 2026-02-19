# Error Guide

When CW encounters an error, it displays the error kind, location, message,
and source context with a caret pointing to the problem.

```
Value error at myfile.clj:3:5
  Expected number, got string

  3 | (+ "hello" 1)
           ^--- Expected number, got string
```

## Error Kinds

### Syntax error

Problem with code structure. Check for:
- Unmatched parentheses, brackets, or braces
- Unterminated strings or regex
- Invalid character literals
- Unexpected EOF

```clojure
;; Bad:  (+ 1 2       ;; missing closing paren
;; Bad:  "unterminated ;; missing closing quote
;; Good: (+ 1 2)
```

### Number format error

Invalid numeric literal.

```clojure
;; Bad:  0x  08r  1.2.3
;; Good: 0xFF  8r77  1.23
```

### Name error

Undefined symbol or unresolved var.

```clojure
;; Unable to resolve symbol: foo in this context
;; → Check spelling, require the namespace, or def the var
(require '[clojure.string :as str])
(str/upper-case "hello")
```

### Arity error

Wrong number of arguments to a function.

```clojure
;; Wrong number of args (3) passed to: clojure.core/inc
;; → inc takes exactly 1 argument
(inc 1 2 3)  ; wrong
(inc 1)      ; correct
```

### Value error

Invalid value for the operation.

```clojure
;; Key already present: :a
;; → Duplicate keys in map literal
{:a 1 :a 2}

;; Can only recur from tail position in fn or loop
(recur 1)  ; not inside fn/loop
```

### Type error

Operation applied to the wrong type.

```clojure
;; Expected number, got :keyword
(+ :a 1)

;; nth not supported on this type
(nth 42 0)
```

### Arithmetic error

Math errors.

```clojure
;; Divide by zero
(/ 1 0)
```

### Index error

Out-of-bounds access.

```clojure
;; Index 5 out of bounds for length 3
(nth [1 2 3] 5)
```

### IO error

File or network operation failed.

```clojure
;; No such file: /nonexistent/path
(slurp "/nonexistent/path")
```

## Stack Traces

When an error occurs inside nested function calls, CW shows the call chain:

```
Arithmetic error at myfile.clj:2:3
  Divide by zero

  2 |   (/ x 0))
         ^--- Divide by zero

  Stack trace:
    user/foo (myfile.clj:2)
    user/bar (myfile.clj:5)
    (REPL:1)
```

## Resource Limits

CW enforces limits to prevent runaway computation:

| Resource | Limit |
|----------|-------|
| Call stack depth (VM) | 32,768 frames |
| Call stack depth (TreeWalk) | 512 |
| Reader nesting depth | 1,024 |
| Reader string size | 1 MB |
| Reader collection size | 100,000 elements |
| Analyzer nesting depth | 1,024 |
| str output size | 10 MB |
| format width/precision | 10,000 |
| Regex string length | 10,000 chars |
| repeat count | 1,000,000 |
| File I/O size | 10 MB |

## Common Fixes

| Error | Fix |
|-------|-----|
| Unable to resolve symbol | `(require '[ns :as alias])` first |
| Wrong number of args | Check function signature with `(doc fn-name)` |
| No such file | Check file path, use absolute path |
| Key not found | Use `(get m :key default)` for safe access |
| Index out of bounds | Use `(get v idx default)` or check `(count v)` |
| Can only recur from tail position | Move `recur` inside `loop` or `fn` |
