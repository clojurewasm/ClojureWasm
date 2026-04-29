---
paths:
  - "src/**/*.zig"
  - "build.zig"
  - "modules/**/*.zig"
---

# Textbook survey before implementation

Auto-loaded when editing Zig sources. Codifies how the `/continue`
per-task TDD loop's **Step 0 (Survey)** consults the reference
codebases without being pulled by their styles.

## The textbooks

| Path                                                               | What it teaches                                                                                         | When to use                                                                                                 |
|--------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| `~/Documents/MyProducts/ClojureWasm/`                              | v1, 89K LOC, 18-month build. Deep Clojure semantics + GC + VM + Wasm interop.                           | Always when introducing a new Clojure feature.                                                              |
| `~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref/`            | Previous redesign Phase 1+2. Closer to current shape.                                                   | When a v2 file already exists in v1_ref under the same name.                                                |
| `~/Documents/OSS/clojure/`                                         | Upstream Clojure JVM. `clojure/lang/{Var, Namespace, RT, LispReader, ...}.java` and `clojure/core.clj`. | When a Clojure language semantic is at stake (var resolution, multimethod dispatch, lazy seq, ex-info, …). |
| `~/Documents/OSS/babashka/`                                        | SCI-based Clojure. Pod system, native-without-JVM precedent.                                            | When the question is "how do other JVM-less Clojures handle X".                                             |
| `~/Documents/OSS/zig/`                                             | Zig 0.16 stdlib source.                                                                                 | When a `std.Io.*` / `std.atomic.*` / `std.process.*` API is in question.                                    |
| `~/Documents/OSS/spec.alpha/`, `malli/`                            | Spec systems.                                                                                           | Phase 14+ spec work only.                                                                                   |
| `~/Documents/OSS/wasmtime/`                                        | Wasm runtime reference.                                                                                 | Phase 14, 19.                                                                                               |
| `~/Documents/OSS/mattpocock_skills/improve-codebase-architecture/` | Module / Interface / Depth / Seam vocabulary.                                                           | When a new module is being introduced.                                                                      |

## Survey procedure (default brief for Explore subagent)

Step 0 of the TDD loop dispatches an Explore subagent. Use this
brief shape:

```
Survey how <CONCEPT> is implemented in:
  - ~/Documents/MyProducts/ClojureWasm  (v1)
  - ~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref  (v1_ref)
  - ~/Documents/OSS/<relevant>          (upstream)

Return 200–400 lines:
  - Files & line ranges where the concept lives
  - Key data shapes (types, fields)
  - Idioms used (Zig 0.16 / Clojure / etc.)
  - Differences across the three sources, with one-line "why each
    chose this"
  - 2–3 places where ClojureWasm v2 should likely DIVERGE based on
    ROADMAP §2 (Inviolable principles): P3 core stays stable, P4 no
    ad-hoc patches, A2 new features via new files, A6 ≤ 1000 lines.

Do NOT copy code. Describe the design space.
```

The summary lands in `private/notes/<phase>-<task>-survey.md`.

## Anti-pull guardrails

A survey is a hazard: reading 89K LOC of v1 makes it tempting to
copy the patterns wholesale. To prevent this:

### Guard 1 — Cite ROADMAP principles before adopting a v1 idiom

For each idiom you import from v1, write one line:

> Adopting v1 `<idiom>` because ROADMAP P# / A# / §N.M aligns with it.

If you can't write that line, the idiom is folklore — re-derive from
ROADMAP first.

### Guard 2 — Always note one DIVERGENCE

Step 0's deliverable must include "where ClojureWasm v2 diverges from
all three textbooks". If it doesn't, the survey was too shallow or
the concept is mechanical (in which case Step 0 should have been
skipped — see below).

### Guard 3 — `pub var` is forbidden, even if v1 uses it

ROADMAP §13 lists patterns to reject regardless of textbook
precedent: `pub var` vtables, `std.Thread.Mutex`, `std.io.AnyWriter`,
JVM-class implementations. The survey may surface these; do not
adopt them.

### Guard 4 — Tier outsiders go to ADR or pod

If v1 has a `lib_X` integration that requires branching code in a
shared file, **do not replicate**. Either write a Tier-promotion
ADR (`.dev/decisions/NNNN_promote_X.md`) or implement as a Wasm
Component pod. ROADMAP §6.4 is non-negotiable.

## When to skip Step 0

Skip only when **all** are true:

- The task is a refactor / rename / doc-only change.
- No new public API is introduced.
- Implementation does not change behaviour observable from outside the
  module.

If any of the above is false, do Step 0 even if "you already know how
v1 did it" — the survey output is the **input to the per-task note**
and the future chapter, not just for your present working memory.

## Where survey notes live

| File                                     | Purpose                                           | Tracked in git?   |
|------------------------------------------|---------------------------------------------------|-------------------|
| `private/notes/<phase>-<task>-survey.md` | Step 0 raw output                                 | No (`.gitignore`) |
| `private/notes/<phase>-<task>.md`        | Step 7 per-task note (digests survey)             | No                |
| `docs/ja/NNNN_<slug>.md`                 | Chapter (digests notes)                           | Yes               |
| `.dev/decisions/NNNN_<slug>.md`          | ADR (load-bearing decisions surfaced from survey) | Yes               |

The flow is: **survey notes → per-task notes → chapter**. Not the
reverse, not skipping a step. Each layer is shorter than the last.
