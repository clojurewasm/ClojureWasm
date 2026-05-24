# `src/runtime/io/`

Consolidated I/O abstraction subsystem. ADR-0015 (Tier 1 / Tier 2
shape) + ADR-0029 D-Consequences (consolidation as the first cw-v1
case study).

| File            | Role                                                                                                                                                                                        |
|-----------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `interface.zig` | **Tier 1** — `Reader` / `Writer` / `File` vtable types, opaque ctx pointers. No `std.Io` import. Consumer code (analyser, REPL, primitives) imports this. (was `runtime/io_interface.zig`) |
| `default.zig`   | **Tier 2** — concrete `std.Io` attachments, `defaultReader()` / `defaultWriter()` constructors. **Lands Phase 5+** as the consumer paths migrate off direct `std.Io.File` references.      |

This directory deliberately holds a single file (`interface.zig`)
during the transition; `default.zig` lands as Phase 5+ progresses
the consumer migration. The directory exists eagerly because Phase
6+ `runtime/java/io/{File, Reader, Writer}.zig` adoption is easier
when the `runtime/io/` parent already exists.

Imports from outside `runtime/io/`:

```zig
const io_interface = @import("../runtime/io/interface.zig");
const io_default = @import("../runtime/io/default.zig");  // Phase 5+
```

Imports inside `runtime/io/` use same-directory bare paths.

The Tier 1 / Tier 2 split is the ADR-0015 design: Tier 1 ships
without `std.Io` so the future `std.Io` reshape only touches Tier
2. See `runtime/io/interface.zig` module docstring for the full
contract.
