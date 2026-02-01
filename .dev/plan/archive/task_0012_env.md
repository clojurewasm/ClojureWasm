# Task 2.1: Create Env (Environment)

## Goal

Create the Env (runtime environment) struct and migrate error threadlocal to
ErrorContext instance (D3a). Env is the foundational struct that will hold
namespaces (Task 2.2), Vars (Task 2.3), and be owned by the VM instance.

## Plan

### Part 1: ErrorContext (D3a)

Move threadlocal state from error.zig to an instance-based ErrorContext.

**Before** (threadlocal):

```zig
threadlocal var last_error: ?Info = null;
threadlocal var msg_buf: [512]u8 = undefined;
pub fn setError(info: Info) Error { ... }
pub fn getLastError() ?Info { ... }
```

**After** (instance):

```zig
pub const ErrorContext = struct {
    last_error: ?Info = null,
    msg_buf: [512]u8 = undefined,

    pub fn setError(self: *ErrorContext, info: Info) Error { ... }
    pub fn setErrorFmt(self: *ErrorContext, ...) Error { ... }
    pub fn getLastError(self: *ErrorContext) ?Info { ... }
};
```

### Part 2: Env struct

Create `src/common/env.zig` with:

```zig
pub const Env = struct {
    allocator: Allocator,
    error_ctx: ErrorContext,

    pub fn init(allocator: Allocator) Env { ... }
    pub fn deinit(self: *Env) void { ... }
};
```

Namespace registry will be added in Task 2.2.

### Part 3: Propagate ErrorContext to Reader/Analyzer

Reader and Analyzer need `*ErrorContext` to call setError.

**Reader**: Add `error_ctx: *err.ErrorContext` field. Update `makeError`.
**Analyzer**: Add `error_ctx: *err.ErrorContext` field. Update `analysisError`.

### Files to modify

| File          | Changes                                                                                                 |
| ------------- | ------------------------------------------------------------------------------------------------------- |
| error.zig     | Add ErrorContext struct, keep module-level fns as thin wrappers (backward compat) or remove threadlocal |
| env.zig (new) | Env struct with ErrorContext                                                                            |
| reader.zig    | Add error_ctx field, update makeError                                                                   |
| analyzer.zig  | Add error_ctx field, update analysisError                                                               |
| build.zig     | Add env.zig to modules if needed                                                                        |

### TDD steps

1. Red: ErrorContext.setError / getLastError round-trip
2. Green: implement ErrorContext
3. Red: Env.init creates valid ErrorContext
4. Green: implement Env
5. Red: Reader with error_ctx reports errors correctly
6. Green: update Reader
7. Red: Analyzer with error_ctx reports errors correctly
8. Green: update Analyzer
9. Refactor: remove threadlocal from error.zig
10. Verify all existing tests pass

### Decision: backward compatibility

Two options for the threadlocal removal:

- **Option A**: Remove threadlocal entirely, require ErrorContext everywhere
- **Option B**: Keep threadlocal as fallback, add instance methods

Option A is cleaner (D3 compliance). Reader/Analyzer init() just needs
an extra `*ErrorContext` parameter. Tests that use Reader/Analyzer already
use ArenaAllocator, so adding an ErrorContext on the stack is trivial.

**Decision: Option A** — full removal of threadlocal.

## Log

- Created ErrorContext struct in error.zig (setError, setErrorFmt, getLastError as instance methods)
- Created Env struct in src/common/env.zig (owns ErrorContext, allocator)
- Added env.zig to root.zig module registry
- Migrated Reader: added error_ctx field, makeError uses self.error_ctx
- Migrated Analyzer: added error_ctx field, analysisError uses self.error_ctx
- Removed all threadlocal variables from error.zig (D3a complete)
- Updated existing tests (2 in error.zig, 1 in reader.zig, 32 in analyzer.zig)
- Updated decisions.md D3a status: Done
- All tests pass
