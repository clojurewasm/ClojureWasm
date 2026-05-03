# 0003 — Adopt zlinter `no_deprecated` as a Mac-host pre-commit gate

- **Status**: Accepted
- **Date**: 2026-05-03
- **Author**: Claude (in-session, on user direction)
- **Tags**: tooling, lint, deprecation, gate, ci

## Context

Zig 0.16 silently accepts pre-0.14/0.15 stdlib names through
deprecation shims (`pub const Foo = NewFoo;` carrying `///
Deprecated:` doc-comments). The compiler emits no warning by
default and there is no `-fdeprecated` flag in 0.16. AI training
corpora overwhelmingly use the old names, and the project has
already accumulated **16 silent deprecation hits** across 9.1 KLoC
that no manual pass surfaced — broken down as:

  - 12 × `std.mem.indexOf{,Scalar}` → `find{,Scalar}` in `src/`
  -  2 × `std.mem.indexOf{,Scalar}` → `find{,Scalar}` in
       `docs/ja/learn_zig/samples/28_mem_utilities.zig`
  -  1 × `std.ArrayListUnmanaged` → `ArrayList` (in `src/runtime/runtime.zig`)
  -  1 × `std.StringArrayHashMapUnmanaged` → `array_hash_map.String`
       (in `src/runtime/keyword.zig`).

Three forces converge:

1. **Manual `zig_tips.md` upkeep cannot keep up.** The rules file
   already covers ~40 stdlib renames, but the project will keep
   adding code (Phase 4 VM, GC, WASI, …) and the stdlib will keep
   deprecating things. A grep-based DIY script would need every
   new pattern added by hand and would lag behind upstream `///
   Deprecated:` annotations.
2. **Zig itself does not have `@deprecated()` shipping in 0.16.**
   The proposal
   ([ziglang/zig#22822](https://github.com/ziglang/zig/issues/22822))
   is accepted on the "urgent" milestone but unmerged; expected
   in 0.17+.
3. **The sister project zwasm v2 has already validated the
   approach** in its own ADR-0009 (commit landed 2026-05-03), with
   sub-second runtime on Mac aarch64 and a clean integration shape.

A web survey of the Zig lint ecosystem (KurtWagner/zlinter,
DonIsaac/zlint, rockorager/ziglint, AnnikaCodes/ziglint)
identified [`KurtWagner/zlinter`](https://github.com/KurtWagner/zlinter)
as the only tool that:

- ships a built-in `no_deprecated` rule that consumes the stdlib's
  own `/// Deprecated:` doc-comments via ZLS-driven AST analysis
  (so it auto-tracks new deprecations without project-side rule
  authoring),
- supports Zig 0.16.x explicitly (alongside 0.14.x / 0.15.x /
  master),
- integrates as a `b.step("lint", ...)` custom build step (matches
  the `zone_check.sh` discipline already in `test/run_all.sh`),
- exits non-zero with `--max-warnings 0`, suitable for CI gating.

## Decision

Add `KurtWagner/zlinter` (pinned to the `0.16.x` branch) as a
project dependency and expose it through a single new build step:

```sh
zig build lint                       # warnings ok, errors fail
zig build lint -- --max-warnings 0   # any finding fails (gate)
```

**Initial rule set: `no_deprecated` only.** Phase B will inspect
the further candidates from zwasm v2's ADR-0009 (`no_orelse_unreachable`,
`no_empty_block`, `require_exhaustive_enum_switch`, `no_unused`)
— that's the *candidate set*; per-rule adoption is decided in
Phase B based on this codebase's own findings (the Update section
records the outcome). The Phase A landing keeps the surface
minimal so the integration itself can be reverted cleanly if
zlinter upstream becomes unmaintained or if `@deprecated()` lands
natively in Zig 0.17+.

The lint step is **Mac-host only**. `test/run_all.sh` detects
`uname -s == Darwin` and runs `zig build lint -- --max-warnings 0`
only on that branch; OrbStack Ubuntu x86_64 skips it with an
informational line. Reasons:

- zlinter requires `zig fetch` against GitHub; OrbStack runs are
  intentionally network-free per `.dev/orbstack_setup.md`.
- Deprecation findings are platform-independent — a single host is
  enough to catch them.

The pre-commit gate documented in `CLAUDE.md` "Working agreement"
gains the lint check as part of the existing `bash test/run_all.sh`
requirement (no separate item, since the script handles platform
detection internally).

## Alternatives considered

### Alternative A — DIY grep script

- **Sketch**: `scripts/zig_deprecation_check.sh` walks `src/` and
  fails if any of a fixed pattern list is matched.
- **Why rejected**: every new stdlib deprecation requires a project
  edit. The current 16-hit count includes patterns (`std.mem.indexOf`)
  that the existing `zig_tips.md` already calls out — yet the code
  drifted in. Manual checklists do not scale; AST-level analysis
  does.

### Alternative B — DonIsaac/zlint

- **Sketch**: Pull in `zlint` instead. It has its own AST-level
  semantic analyser and rules like `unsafe-undefined`, `homeless-try`.
- **Why rejected**: deprecation detection is not its focus
  ([README rule list](https://github.com/DonIsaac/zlint)). For a
  project that mostly cares about stdlib API drift this is the
  wrong axis.

### Alternative C — Wait for `@deprecated()` builtin

- **Sketch**: Don't adopt anything; wait for ziglang/zig#22822 to
  land natively (likely 0.17.x).
- **Why rejected**: open-ended schedule. Phases 4 → 7 will accumulate
  more code in the meantime, increasing the cost of the eventual
  back-fix sweep. The cost of adopting and later replacing zlinter
  is a single `build.zig` revert and dependency removal — small
  enough to make the wait-and-see option strictly worse.

### Alternative D — All-builtins-on initial integration

- **Sketch**: Enable all 25 zlinter built-in rules from the start.
- **Why rejected**: zwasm v2's spike showed 81 errors + 1314
  warnings under the same blanket-on configuration, the bulk from
  rules mismatched to project conventions (`declaration_naming`
  requires identifier length ≥ 3, but the codebase uses math
  conventions like `i`, `n`, `rt`). Phase B will widen the rule
  set deliberately, one rule at a time.

## Consequences

- **Positive**:
  - Zero-maintenance deprecation tracking — zlinter consumes the
    stdlib's own `/// Deprecated:` annotations.
  - One-step gate semantics: `zig build lint -- --max-warnings 0`.
  - Sub-second on Mac aarch64; small enough to gate every commit
    without perceptible overhead.
  - Surfaces the 16 already-rotted call sites that prior manual
    passes missed.

- **Negative**:
  - First external dependency in `build.zig.zon`.
  - Dependent on a third-party project (`KurtWagner/zlinter`); if
    upstream stops shipping a 0.16-compatible branch, we either
    fork or fall back to grep.
  - Mac-only enforcement means a Linux-only contributor (none today)
    could merge without running it. Mitigation: the `/continue`
    skill always runs on Mac native first.

- **Neutral / follow-ups**:
  - **Phase B** — widen the rule set per zwasm ADR-0009's validated
    list (`no_orelse_unreachable`, `no_empty_block`,
    `require_exhaustive_enum_switch`, `no_unused`). Each rule lands
    one at a time with a fix pass.
  - **Phase C** — case-by-case judgment for the remaining low-
    finding rules; deferred until Phase B settles.
  - **Sunset path**: when `@deprecated()` and `-fdeprecated` ship
    in Zig (likely 0.17+), revisit this ADR. Native compiler
    enforcement may obsolete the zlinter dependency entirely.
    The sunset trigger is `ziglang/zig#22822`; track it informally
    until a `proposal_watch.md` lands in this project.
  - `zig-pkg/` (zlinter's package cache) is added to `.gitignore`.

## Update — 2026-05-03 (Phase B outcome)

Phase B walked the four candidate rules from zwasm ADR-0009.
Outcome:

| Rule                             | Phase | Findings | Outcome     | Notes                                                                                                                                                                                                                                                                                                                                                                                                            |
|----------------------------------|-------|----------|-------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `no_deprecated`                  | A     | 16 → 0  | **Adopted** | The original Phase-A landing.                                                                                                                                                                                                                                                                                                                                                                                    |
| `no_orelse_unreachable`          | B     | 0        | **Adopted** | Codebase already used `x.?` everywhere; rule is a forward guard.                                                                                                                                                                                                                                                                                                                                                 |
| `no_empty_block`                 | B     | 0        | **Adopted** | Codebase already comments empty bodies; forward guard.                                                                                                                                                                                                                                                                                                                                                           |
| `no_unused`                      | B     | 1 → 0   | **Adopted** | Removed dead `error_mod` import in `src/lang/bootstrap.zig:35`.                                                                                                                                                                                                                                                                                                                                                  |
| `require_exhaustive_enum_switch` | B     | 12       | Not adopted | Mismatched with the project's `Value.Tag` dispatch idiom (36+ tags, intentionally growing through Phases 4–15). Arithmetic / collection / print primitives all use `else =>` to mean "every other kind I do not accept as operand", which is the correct semantic and would degenerate into 36-arm enumeration with no regression-prevention payoff. Re-evaluate when `Value.Tag` stabilises (Phase 8+ likely). |

Lint runtime stays sub-second on Mac aarch64. The Phase A "Mac-
only" / "skipped on Linux" decisions stand.

The project deviation from zwasm ADR-0009's adopted set
(4 vs 5 rules) is intentional — the difference reflects the
shape of this codebase's central enum, not a judgement on the
rule itself.

## References

- ROADMAP §11 (test strategy / quality gate) and §12 (commit
  discipline) — the lint gate slots into the existing
  `test/run_all.sh` single-entry pattern.
- Sister project: zwasm v2 ADR-0009 (`~/Documents/MyProducts/zwasm_from_scratch/.dev/decisions/0009_zlinter_no_deprecated_gate.md`)
  — the full Phase B / C playbook plus the per-builtin survey.
- Upstream: [KurtWagner/zlinter](https://github.com/KurtWagner/zlinter)
- Native proposal: [ziglang/zig#22822 — `@deprecated()`
  builtin](https://github.com/ziglang/zig/issues/22822)
