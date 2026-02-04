# T15.5.1: Core Test VM + TreeWalk Dual-Backend Verification

## Goal

Run `test/upstream/sci/core_test.clj` on both VM and TreeWalk backends.
Fix issues found during VM execution.

## Issues Found & Fixed

### Issue 1: VM variadic rest args not collected into list

`(fn [x & xs] xs)` with `(f 1 2 3)` returned `2` instead of `(2 3)`.
**Fix**: In `VM.performCall()`, collect rest args into PersistentList.

### Issue 2: Multi-arity exact match not prioritized over variadic

`((fn ([x & xs] "variadic") ([x] "otherwise")) 1)` returned "variadic".
**Fix**: `findProtoByArity()` now searches exact matches first, then variadic.

### Issue 3: Non-contiguous closure capture (MAJOR — D56)

`capture_base + capture_count` contiguous approach failed when self-ref and
var_load created gaps in stack slots. Example: self-ref at 0, var_load at 1,
let binding at 2 — but capture expected contiguous from 0.
**Fix**: Added `capture_slots: []const u16` to FnProto for per-slot capture.

### Issue 4: Set and Map as IFn not supported in VM

`(#{:a :b :c} :a)` caused VM error.
**Fix**: Added `.set` and `.map` dispatch in `performCall()`.

### Issue 5: Namespace-qualified var resolution incomplete

`(clojure.string/upper-case "hello")` failed on VM.
**Fix**: Added fallback lookup in `env.namespaces` for qualified names.

### Issue 6: FRAMES_MAX too small (64)

Recursion of 72 levels exceeded stack. Increased to 256, STACK_MAX to 256\*128.

### Issue 7: capture_slots memory leak in compiler deinit

`capture_slots` allocated in `emitFn` was not freed in `Compiler.deinit()`.
**Fix**: Added `allocator.free(proto.capture_slots)` in deinit loop.

### Remaining: defmulti/defmethod VM compilation (F13)

VM compiler returns `error.InvalidNode` for defmulti/defmethod nodes.
Documented as existing F13 item. 1 test excluded.

## Results

- Zig unit tests: 939/939 pass, 0 leaks
- VM: 71/72 tests, 264 assertions pass (multimethod excluded)
- TreeWalk: 72/72 tests, 267 assertions pass (all)

## Log

- Fixed 7 VM issues enabling core_test dual-backend verification
- D56 added for capture_slots design decision
- F75 resolved (closure capture with named fn self-ref)
