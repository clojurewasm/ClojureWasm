# T13.2: Named fn self-reference + fn param shadow fixes

## Plan

### 1. Named fn self-reference

**Problem**: `(fn foo [] foo)` returns a different Fn object each call.
Each call to callClosure creates a new `Fn` wrapper at tree_walk.zig:286-294.

**Fix**: Create the Fn wrapper once when first entering the closure, then
reuse it for the self-reference binding. The caller's fn_val (passed in)
is the correct identity — bind that directly instead of creating a new one.

Key: in callClosure, the callee fn_val is the correct identity.
We need to pass it through so the name binding uses it.

### 2. fn param name shadows special form

**Problem**: `(fn [if] if)` crashes because analyzeList checks special_forms
before checking local bindings.

**Fix**: In analyzer.zig analyzeList, check findLocal before special_forms.get
when the head symbol could be a local binding.

## Log

- Fixed named fn self-reference: pass callee_fn_val to callClosure, bind it directly
- Fixed fn param shadow: analyzer.zig checks findLocal before special_forms.get
- Enabled self-ref-test and fn-param-shadow assertion in SCI tests
- SCI: 72/74 tests pass, 259 assertions (was 71/74, 257)
