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

## `note` Field

Optional developer notes for deviations, constraints, or implementation details.

Common patterns:

| Note                            | Meaning                                         |
| ------------------------------- | ----------------------------------------------- |
| `"VM intrinsic opcode"`         | Compiled to direct VM opcode for fast execution |
| `"analyzer special form in CW"` | Macro in upstream, special form in ClojureWasm  |
| `"portable to clj"`             | Zig builtin that could be migrated to .clj      |
| `"eager (no lazy seq)"`         | Upstream is lazy, this impl is eager            |

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

# Find unimplemented functions
yq '.vars.clojure_core | to_entries[] | select(.value.status == "todo" and .value.type == "function") | .key' .dev/status/vars.yaml

# Find skipped vars (JVM-specific)
yq '.vars.clojure_core | to_entries[] | select(.value.status == "skip") | .key' .dev/status/vars.yaml

# Find entries with notes
yq '.vars.clojure_core | to_entries[] | select(.value.note) | .key + " -> " + .value.note' .dev/status/vars.yaml

# Find VM intrinsics
yq '.vars.clojure_core | to_entries[] | select(.value.note == "VM intrinsic opcode") | .key' .dev/status/vars.yaml

# Find deviations from upstream (analyzer special forms)
yq '.vars.clojure_core | to_entries[] | select(.value.note == "analyzer special form in CW") | .key' .dev/status/vars.yaml

# List all namespaces
yq '.vars | keys' .dev/status/vars.yaml

# Count by type (done only)
yq '[.vars.clojure_core | to_entries[] | select(.value.status == "done") | .value.type] | group_by(.) | map({(.[0]): length})' .dev/status/vars.yaml

# Benchmark history
yq '.history' .dev/status/bench.yaml
```
