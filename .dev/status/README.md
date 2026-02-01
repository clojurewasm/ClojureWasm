# Status Tracking

Structured data for tracking behavioral compatibility with upstream Clojure.

---

## Files

| File         | Content                                            |
| ------------ | -------------------------------------------------- |
| `vars.yaml`  | Var implementation status (functions, macros, etc) |
| `bench.yaml` | Benchmark results and history                      |

---

## Status Definitions

| Status    | Meaning                                         |
| --------- | ----------------------------------------------- |
| `todo`    | Not yet implemented                             |
| `wip`     | In progress (exists but incomplete)             |
| `partial` | Partial implementation (some features deferred) |
| `done`    | Complete (with tests)                           |
| `skip`    | Will not implement (JVM-specific, etc)          |

---

## Var `type` Definitions

Classification in upstream Clojure.

| Type           | Description                   |
| -------------- | ----------------------------- |
| `special-form` | Handled directly by evaluator |
| `function`     | Function                      |
| `macro`        | Macro                         |
| `dynamic-var`  | Dynamically bindable Var      |
| `var`          | Regular Var (non-function)    |

---

## `impl` Definitions

Implementation method in this project.

| impl           | Description                                              |
| -------------- | -------------------------------------------------------- |
| `special_form` | Analyzer direct dispatch                                 |
| `intrinsic`    | VM opcode fast path (+, -, \*, /, mod, rem, comparisons) |
| `host`         | Zig BuiltinFn — Zig required (Value internals, IO)       |
| `bridge`       | Zig BuiltinFn — .clj migration candidate                 |
| `clj`          | Defined in Clojure source (.clj files)                   |
| `none`         | Not yet implemented                                      |

### Provisional Special Forms

Entries where `type: function` + `impl: special_form` indicate a
"provisional special form" — a function in upstream Clojure that is
implemented as a special form in this project (e.g., `defmacro`).

### Bridge Functions

Entries with `impl: bridge` are implemented in Zig for practical reasons
(bootstrap order, performance) but could be migrated to .clj in the future.

---

## bench.yaml Structure

```yaml
env: # Hardware and build configuration
benchmarks: # Benchmark definitions (name, command, expected result)
history: # Results over time (append new entry after optimization)
  - date: YYYY-MM-DD
    version: "phase/optimization name"
    results:
      benchmark_name: { time_ms: value, stddev_ms: value }
```

When a performance optimization is applied, append a new entry to `history`.

---

## yq Query Examples

```bash
# Count implemented vars in clojure.core
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml

# Find provisional special forms (functions implemented as special forms)
yq '.vars.clojure_core | to_entries[] | select(.value.type == "function" and .value.impl == "special_form") | .key' .dev/status/vars.yaml

# Count by impl (done only)
yq '[.vars.clojure_core | to_entries[] | select(.value.status == "done") | .value.impl] | group_by(.) | map({(.[0]): length})' .dev/status/vars.yaml

# Find .clj migration candidates
yq '.vars.clojure_core | to_entries[] | select(.value.impl == "bridge") | .key' .dev/status/vars.yaml

# Zig-required total (host + intrinsic + special_form)
yq '.vars.clojure_core | to_entries | map(select(.value.impl == "host" or .value.impl == "intrinsic" or .value.impl == "special_form")) | length' .dev/status/vars.yaml

# Find unimplemented functions
yq '.vars.clojure_core | to_entries[] | select(.value.status == "todo" and .value.type == "function") | .key' .dev/status/vars.yaml

# Find skipped vars (JVM-specific)
yq '.vars.clojure_core | to_entries[] | select(.value.status == "skip") | .key' .dev/status/vars.yaml

# List all namespaces
yq '.vars | keys' .dev/status/vars.yaml

# Count by impl
yq '[.vars.clojure_core | to_entries[] | select(.value.status == "done") | .value.impl] | group_by(.) | map({(.[0]): length})' .dev/status/vars.yaml

# Benchmark history
yq '.history' .dev/status/bench.yaml
```
