# T12.7: Namespace ops II: ns-map, ns-publics, ns-interns

## Goal

Add namespace Var mapping introspection builtins.

## Plan

1. Add ns-interns, ns-publics, ns-map to ns_ops.zig
2. Helper: resolveNs (symbol -> Namespace), varMapToValue (VarMap -> Value map)
3. ns-publics == ns-interns (no private vars yet)
4. ns-map combines interned + referred mappings

## Log

- Added 3 builtins to ns_ops.zig
- Helper functions: resolveNs(), varMapToValue()
- 4 unit tests: ns-interns on core, ns-publics parity, ns-map includes refers, user ns empty interns
- Registry: 146 -> 149 builtins
- CLI verified: (count (ns-interns 'clojure.core)) = 251
- All tests pass (full suite)
