# Status Tracking

Structured data for tracking progress.

## Files

| File        | Content                   |
|-------------|---------------------------|
| `vars.yaml` | Var implementation status |

Benchmark history: `bench/history.yaml`

## vars.yaml

**Status values**: `done`, `todo`, `skip`

**Note conventions**:

| Note                               | Meaning                                         |
|------------------------------------|-------------------------------------------------|
| `"VM intrinsic opcode"`            | Compiled to direct VM opcode for fast execution |
| `"analyzer special form in CW"`    | Macro in upstream, special form in ClojureWasm  |
| `"builtin (upstream is pure clj)"` | Zig builtin, upstream is pure Clojure           |
| `"UPSTREAM-DIFF: ..."`             | Simplified implementation, details in note      |
| `"JVM interop"`                    | JVM-specific, not applicable                    |

## yq Query Examples

```bash
# Count done vars
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' vars.yaml

# Total vars
yq '.vars.clojure_core | to_entries | length' vars.yaml

# Find todo functions
yq '.vars.clojure_core | to_entries[] | select(.value.status == "todo" and .value.type == "function") | .key' vars.yaml

# Find entries with notes
yq '.vars.clojure_core | to_entries[] | select(.value.note) | .key + " -> " + .value.note' vars.yaml
```
