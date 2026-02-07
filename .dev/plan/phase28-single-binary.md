# Phase 28: Single Binary Builder

## Goal

`cljw build app.clj -o app` — embed user Clojure source in a self-contained
executable. No source files needed at runtime.

**Design principle**: Maximize simplicity. Ship working single binary ASAP,
iterate on AOT and multi-file later.

## Prior Art

| Tool            | Approach                       | User needs toolchain? |
| --------------- | ------------------------------ | --------------------- |
| Deno compile    | Binary trailer (Sui section)   | No                    |
| Node.js SEA     | postject resource injection    | No                    |
| Babashka        | GraalVM native-image           | Yes (GraalVM)         |
| Go embed        | @embedFile at compile-time     | Yes (Go)              |
| ClojureWasm     | Binary trailer (Phase 28.1)    | No                    |

**Chosen approach**: Binary trailer (Deno-style). No Zig toolchain required
on the user's machine. Fast build (just file copy + append).

## Binary Trailer Format

### Version 1 (Phase 28.1 — single .clj)

```
[original cljw binary bytes]
[payload: user .clj source bytes]
[payload_size: u64 LE]     — 8 bytes
[magic: "CLJW"]            — 4 bytes
```

Total trailer overhead: 12 bytes. Detection: read last 12 bytes of self,
check magic, extract payload_size.

### Version 2 (Phase 28.2 — multi-section, future)

```
[original cljw binary bytes]
[section 0: .clj source bytes]
[section 1: .wasm module bytes]
...
[section table:]
  for each section:
    type: u32 LE    — 1=clj_source, 2=wasm_module, 3=aot_bytecode
    offset: u64 LE  — from start of first section
    size: u64 LE
    name_len: u16 LE
    name: [u8; name_len]
[n_sections: u32 LE]
[table_size: u32 LE]  — size of section table (for seeking back)
[version: u16 LE]     — 2
[magic: "CLJW"]       — 4 bytes
```

v1 detection: last 4 bytes = "CLJW", preceding 8 bytes = payload_size,
no version field → version 1 assumed (payload_size < 2^48 guardrail).

v2 detection: last 4 bytes = "CLJW", preceding 2 bytes = version == 2,
then preceding 4 bytes = table_size, use table_size to read section table.

Forward-compatible: v2 reader checks version before interpreting trailer.
v1 reader ignores version > 1 (falls through to normal arg parsing).

## Sub-phases

### 28.1: Source Embedding (MVP)

Single .clj file baked into binary. No Zig toolchain needed.

**Tasks:**

| Task   | Description                                          | Est. |
| ------ | ---------------------------------------------------- | ---- |
| 28.1a  | Embedded source detection at startup                 | S    |
| 28.1b  | `build` subcommand implementation                    | M    |
| 28.1c  | Built binary CLI args as `*command-line-args*`       | S    |
| 28.1d  | Integration test (build + run + verify)              | S    |

**28.1a: Embedded source detection**

Add to main.zig, before argument parsing:

```zig
fn readEmbeddedSource(allocator: Allocator) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&path_buf) catch return null;
    const file = std.fs.openFileAbsolute(self_path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    const file_size = stat.size;
    if (file_size < 12) return null;

    // Read trailer (last 12 bytes)
    file.seekTo(file_size - 12) catch return null;
    var trailer: [12]u8 = undefined;
    _ = file.readAll(&trailer) catch return null;

    // Check magic
    if (!std.mem.eql(u8, trailer[8..12], "CLJW")) return null;

    // Extract payload size
    const payload_size = std.mem.readInt(u64, trailer[0..8], .little);
    if (payload_size == 0 or payload_size > file_size - 12) return null;

    // Read payload
    file.seekTo(file_size - 12 - payload_size) catch return null;
    const source = allocator.alloc(u8, payload_size) catch return null;
    _ = file.readAll(source) catch { allocator.free(source); return null; };
    return source;
}
```

Main flow:
```
main() {
    if (readEmbeddedSource()) |source| {
        // Embedded mode: evaluate source and exit
        evalEmbedded(source, args[1..]);  // pass remaining args
        return;
    }
    // Normal mode: parse args, REPL, etc.
    ...
}
```

**28.1b: Build command**

CLI: `cljw build <source.clj> [-o <output>]`

```zig
fn handleBuildCommand(allocator: Allocator, args: [][]const u8) void {
    // Parse: source_file, -o output_file
    // Default output: source without .clj extension

    // 1. Read self binary
    const self_bytes = readSelfBinary(allocator);

    // 2. Read user .clj source
    const user_source = readFile(allocator, source_file);

    // 3. Write output: self + source + trailer
    const out = createFile(output_path);
    out.writeAll(self_bytes);
    out.writeAll(user_source);
    out.writeAll(u64_to_le_bytes(user_source.len));
    out.writeAll("CLJW");

    // 4. chmod +x
    std.posix.fchmod(out.handle, 0o755);
}
```

**28.1c: CLI args forwarding**

Built binary passes remaining args to `*command-line-args*`:

```
./app arg1 arg2
;; *command-line-args* => ("arg1" "arg2")
```

Implement by setting a dynamic var in Env before evaluating embedded source.

**28.1d: Integration test**

```bash
# Build
./zig-out/bin/cljw build test/hello.clj -o /tmp/hello

# Run
/tmp/hello                    # prints "Hello, World!"
/tmp/hello foo bar            # *command-line-args* = ("foo" "bar")

# Size check
ls -la /tmp/hello             # ~1.7MB (cljw) + source bytes
```

### 28.2: Wasm Pre-linking (future)

Embed .wasm modules alongside .clj source. v2 trailer format.

**Tasks:**

| Task   | Description                                          |
| ------ | ---------------------------------------------------- |
| 28.2a  | v2 trailer format: multi-section support             |
| 28.2b  | `build --wasm math.wasm` flag                        |
| 28.2c  | Runtime: load embedded .wasm instead of file          |

**Scope**: User specifies .wasm files at build time. At runtime, `wasm/load`
checks embedded modules before filesystem. Pre-linking avoids file I/O.

### 28.3: AOT Bytecode (future, blocked by F7)

Pre-compile .clj to bytecode chunks, embed bytecode instead of source.

**Blocked by**: F7 (macro body serialization). Macros defined in core.clj
must be serializable to bytecode for AOT to work. Currently, macros are
TreeWalk closures that capture Env state — not serializable.

**Tasks (when F7 resolved):**

| Task   | Description                                          |
| ------ | ---------------------------------------------------- |
| 28.3a  | Bytecode serialization format                        |
| 28.3b  | Compiler: .clj -> bytecode chunk file (.cljc)        |
| 28.3c  | `build --aot` flag: compile then embed bytecode      |
| 28.3d  | Runtime: deserialize + execute bytecode directly     |

**Expected benefit**: Skip Reader + Analyzer at startup. Instant execution.

## Design Decisions

### Why binary trailer, not Zig @embedFile rebuild?

| Factor            | Trailer          | @embedFile rebuild    |
| ----------------- | ---------------- | --------------------- |
| User needs Zig?   | No               | Yes                   |
| Build speed       | ~instant         | ~seconds              |
| Cross-compile     | No               | Yes (Zig strength)    |
| AOT possible      | No (source only) | Yes                   |
| Binary size       | Same + source    | Potentially smaller   |

Phase 28.1 uses trailer for zero-dependency UX. Phase 28.3 (AOT) may
introduce optional @embedFile rebuild for optimized binaries.

### macOS Code Signing

Binary trailer append invalidates Mach-O code signatures. Mitigations:

1. **Ad-hoc resign**: `codesign -s - -f app` after build (automated)
2. **Section injection**: Future enhancement using Mach-O `__DATA` segment
3. **Zig rebuild**: Phase 28.3 produces properly signed binaries

For development/CLI use, ad-hoc signing is sufficient. Gatekeeper only
blocks unsigned .app bundles, not CLI binaries run from terminal.

### Multi-file projects

Phase 28.1 supports single .clj file only. Multi-file support options:

1. **Uberscript**: Concatenate all .clj files into one (Babashka approach)
2. **Tar/zip payload**: Bundle src/ directory in trailer
3. **require resolution**: Build command resolves requires, includes deps

Decision deferred to Phase 28.2 or 30 (zero-config project model).

## Success Criteria

- [ ] `cljw build hello.clj -o hello` produces working binary
- [ ] Built binary starts with full runtime (all 526 vars available)
- [ ] `*command-line-args*` populated from binary's argv
- [ ] Binary size: base (~1.7MB) + source + 12 bytes overhead
- [ ] No Zig toolchain needed on user's machine
- [ ] Works on macOS (Darwin) and Linux

## References

- D79: Native production track pivot
- F106: Single binary builder checklist item
- F7: Macro serialization (AOT blocker)
- SS21: Deployment paths (future.md)
- Deno compile: https://docs.deno.com/runtime/reference/cli/compile/
- Node.js SEA: https://nodejs.org/api/single-executable-applications.html
