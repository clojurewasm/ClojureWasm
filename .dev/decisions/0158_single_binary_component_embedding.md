# ADR-0158 — `cljw build`: embed `:require`d Wasm components into the single binary

- **Status**: Proposed → Accepted (2026-06-21, user-directed)
- **Driven by**: the user directive that a module which `(:require ["x.wasm" :as x])`s a
  Wasm component must, after `cljw build`, produce a **self-contained single binary** (no
  external `.wasm` at runtime). Single-binary deployability is a cljw selling point
  (lightweight + CLI-handy) and must not be forfeited when the new-code worldview reaches
  for Wasm components (ADR-0135 Amendment 1).
- **Relates to**: ADR-0135 (component-as-namespace, the surface), ADR-0034 (`cljw build`
  bytecode envelope), F-001 (zwasm embedding), F-016 (always-latest Wasm/WASI consumer
  invariant). External: zwasm's Component-Model embedding API (functional, default-ON).

## Context

`cljw build` compiles a program + the bundled `.clj` core to one **bytecode envelope**
embedded in the binary (`app/builder.zig`: `buildEnvelope` / `buildBootstrapEnvelope`);
the embedded-run startup installs an **embedded-only resolver** that serves the bundled
namespaces from the envelope instead of the filesystem (so a shipped binary needs no
`.clj` on disk). ADR-0135 Amendment 1 adds `(:require ["x.wasm" :as x])` — a component
load. Naively, the built binary would still read `x.wasm` from the filesystem at runtime,
breaking the single-binary contract.

## Decision

**`cljw build` embeds the bytes of every statically-resolvable `:require`d component into
the envelope, and the embedded-run startup resolves component `:require`s from those bytes
— a parallel arm to the existing embedded `.clj` resolver.**

1. **Collect (build time)**: while compiling, the builder records each string-libspec
   component `:require` it encounters, resolves it (ADR-0135 A2 order: relative / absolute
   / classpath), and reads the `.wasm` bytes.
2. **Embed**: the bytes go into a **component table** in the envelope (keyed by the
   resolved logical id — the alias or normalized path), beside the bytecode. Raw component
   bytes are embedded **as-is** (not native-precompiled — see Alternatives); the embedded
   zwasm loads/JITs them at runtime exactly as a filesystem load would.
3. **Resolve (embedded run)**: startup installs an **embedded component resolver** that,
   given a `:require`d component id, returns the embedded bytes (and only falls through to
   the filesystem for a genuinely dynamic `(wasm/load "runtime.wasm")` whose target was not
   known at build time). So `(:require ["x.wasm" :as x])` in a built binary loads from
   memory; the binary is self-contained + portable.

The mechanism mirrors the `.clj` envelope arm exactly (embedded table + embedded-only
resolver), so it is *addition, not new subsystem*.

## Alternatives considered

- **Native-precompile each component (Cranelift `.cwasm` / Wasmer `create-exe`
  object+link)** — rejected for v1: it ties the binary to one CPU arch (the cljw binary is
  cross-arch via `-Dcpu=baseline`), is far heavier (a linker step per component), and
  loses parity with the filesystem-load path (which loads raw bytes). Embedding raw bytes
  keeps one load path (the embedded zwasm JITs at runtime, same as a normal load) and stays
  arch-neutral. A precompile fast-path can be added later for cold-start without changing
  this contract.
- **External `.wasm` sidecar next to the binary** — rejected: defeats the single-binary
  contract the user explicitly requires.
- **Embed every component, including dynamic `(wasm/load runtime-path)`** — impossible: a
  path only known at runtime cannot be embedded at build time. So the embeddable set is
  the **statically-resolvable `:require`-string** components; truly-dynamic `wasm/load`
  remains a filesystem read in the built binary (documented; the embedded resolver falls
  through). This is the correct boundary, not a gap.

## Consequences

- A `cljw build`'d program that `:require`s components is **fully self-contained** — one
  portable binary, no `.wasm` sidecars. Startup loads components from memory (no FS).
- **Binary size** grows by the embedded component sizes (a markdown component ~hundreds of
  KB). Acceptable + expected; the builder should `log` the embedded component count + total
  bytes so the size is visible, not silent.
- The boundary "static `:require` = embeddable / dynamic `wasm/load` = filesystem" is a
  clear, documented contract; it mirrors how AOT vs runtime-`require` already differ.
- No core-VM risk: all `-Dwasm`-flag-guarded; the default gate never resolves zwasm (F-001).

## Affected files (when implemented)

- `app/builder.zig` (the component-collection + embed into the envelope; the embedded
  component resolver at startup), `runtime/cljw/wasm/component.zig` + the resolution arm
  from ADR-0135 A2 (a load-from-embedded-bytes path beside load-from-file), the envelope
  serialize/deserialize (`eval/bytecode/serialize.zig`) for the component table.
- Tracked as ADR-0135's implementation phase **D** (sub-row of the D-404 epic).

### Sources (research, 2026-06-21)

- Single-binary Wasm embedding precedents: Wasmtime pre-compiling (`.cwasm`,
  `engine.precompile_module`), Wasmer `create-exe` (wasm → static object → C-linker). Both
  inform the *rejected* native-precompile alternative; cljw embeds raw bytes for arch
  neutrality + load-path parity.