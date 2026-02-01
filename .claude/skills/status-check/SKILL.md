---
name: status-check
description: >
  Check implementation status of Clojure vars using .dev/status/vars.yaml.
  Use when user says "status check", "var status", "implementation coverage",
  "what's implemented", or when checking progress on a specific namespace.
compatibility: Claude Code only. Requires .dev/status/vars.yaml.
user_invocable: true
metadata:
  author: clojurewasm
  version: 1.0.0
---

# Status Check

Check ClojureWasm implementation coverage against upstream Clojure.

## Steps

1. Read `.dev/status/vars.yaml` to get current implementation data
2. Run yq queries to compute statistics:

```bash
# Total done in clojure.core
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml

# Total vars in clojure.core
yq '.vars.clojure_core | to_entries | length' .dev/status/vars.yaml

# By status
yq '[.vars.clojure_core | to_entries[] | .value.status] | group_by(.) | map({(.[0]): length})' .dev/status/vars.yaml

# By impl (done only)
yq '[.vars.clojure_core | to_entries[] | select(.value.status == "done") | .value.impl] | group_by(.) | map({(.[0]): length})' .dev/status/vars.yaml

# Provisional special forms (function in upstream, special_form in our impl)
yq '.vars.clojure_core | to_entries[] | select(.value.type == "function" and .value.impl == "special_form") | .key' .dev/status/vars.yaml

# All namespaces with done counts
for ns in $(yq '.vars | keys | .[]' .dev/status/vars.yaml); do
  total=$(yq ".vars.$ns | to_entries | length" .dev/status/vars.yaml)
  done=$(yq ".vars.$ns | to_entries | map(select(.value.status == \"done\")) | length" .dev/status/vars.yaml)
  echo "$ns: $done/$total"
done
```

3. Present a summary table:
   - Coverage by namespace (done/total)
   - Implementation type breakdown (intrinsic/builtin/special_form/clj/macro)
   - Provisional special forms list
   - Recently implemented vars (if context available)

4. If the user asks about a specific namespace, show unimplemented functions:

```bash
yq '.vars.NAMESPACE | to_entries[] | select(.value.status == "todo" and .value.type == "function") | .key' .dev/status/vars.yaml
```

## Output Format

```
## Implementation Status

| Namespace      | Done | Total | Coverage |
| -------------- | ---- | ----- | -------- |
| clojure_core   | 95   | 700+  | ~14%     |
| clojure_string | 0    | 21    | 0%       |
| ...            |      |       |          |

### By Implementation Method (clojure.core done)
- special_form: 15 (Analyzer dispatch)
- intrinsic: 12 (VM opcodes: +, -, *, /, mod, rem, =, not=, <, >, <=, >=)
- host: 42 (Zig required BuiltinFn)
- bridge: 3 (Zig BuiltinFn, .clj migration candidate)
- clj: 23 (core.clj definitions)

### Provisional Special Forms
- defmacro (macro in upstream, special_form here)
```
