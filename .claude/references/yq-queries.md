# vars.yaml Quick Queries (yq)

## Read Queries

```bash
# Implementation coverage (clojure.core)
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml

# Total vars in clojure.core
yq '.vars.clojure_core | to_entries | length' .dev/status/vars.yaml

# All namespaces
yq '.vars | keys' .dev/status/vars.yaml

# Check specific var
yq '.vars.clojure_core["var-name"]' .dev/status/vars.yaml

# Unimplemented functions
yq '.vars.clojure_core | to_entries[] | select(.value.status == "todo" and .value.type == "function") | .key' .dev/status/vars.yaml

# Entries with notes
yq '.vars.clojure_core | to_entries[] | select(.value.note) | .key + " -> " + .value.note' .dev/status/vars.yaml

# Count by status
yq '[.vars.clojure_core | to_entries[] | .value.status] | group_by(.) | map({(.[0]): length})' .dev/status/vars.yaml

# Count by type (done only)
yq '[.vars.clojure_core | to_entries[] | select(.value.status == "done") | .value.type] | group_by(.) | map({(.[0]): length})' .dev/status/vars.yaml

# Find upstream deviations
grep UPSTREAM-DIFF .dev/status/vars.yaml
```

## Update Queries

```bash
# Set status to done
yq -i '.vars.clojure_core["var-name"].status = "done"' .dev/status/vars.yaml

# Set status to skip (JVM-specific)
yq -i '.vars.clojure_core["var-name"].status = "skip"' .dev/status/vars.yaml

# Add note
yq -i '.vars.clojure_core["var-name"].note = "builtin (upstream is pure clj)"' .dev/status/vars.yaml

# Set impl type
yq -i '.vars.clojure_core["var-name"].impl = "builtin"' .dev/status/vars.yaml

# Batch update: mark multiple vars as done
for var in first rest cons conj; do
  yq -i ".vars.clojure_core[\"$var\"].status = \"done\"" .dev/status/vars.yaml
done
```

## Note Conventions

- `"JVM interop"` — JVM-specific, not applicable to ClojureWasm
- `"builtin (upstream is pure clj)"` — Zig builtin, upstream is pure Clojure
- `"VM intrinsic opcode"` — Optimized VM instruction
- `"UPSTREAM-DIFF: <what>; missing: <deps>"` — Simplified implementation
