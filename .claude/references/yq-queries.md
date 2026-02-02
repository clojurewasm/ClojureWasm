# vars.yaml Quick Queries (yq)

```bash
# Implementation coverage (clojure.core)
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' .dev/status/vars.yaml

# All namespaces
yq '.vars | keys' .dev/status/vars.yaml

# Unimplemented functions
yq '.vars.clojure_core | to_entries[] | select(.value.status == "todo" and .value.type == "function") | .key' .dev/status/vars.yaml

# Entries with notes
yq '.vars.clojure_core | to_entries[] | select(.value.note) | .key + " -> " + .value.note' .dev/status/vars.yaml

# Count by type (done only)
yq '[.vars.clojure_core | to_entries[] | select(.value.status == "done") | .value.type] | group_by(.) | map({(.[0]): length})' .dev/status/vars.yaml

# Find upstream deviations
grep UPSTREAM-DIFF .dev/status/vars.yaml
```
