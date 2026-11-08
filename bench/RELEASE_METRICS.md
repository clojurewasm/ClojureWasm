# Release metrics

The number ClojureWasm locks as its headline is **binary size**, because it is
*reproducible*: given a Zig version and target, anyone re-running the build gets
the same bytes. Cold start is reported too, but as a secondary,
machine-dependent figure (it varies with CPU and filesystem cache).

Reproduce both:

```sh
bash bench/release_metrics.sh
```

## Locked figure

There is exactly **one** shipped configuration, and it is the one users
download: `-Dwasm -Doptimize=ReleaseSafe`, with the zwasm JIT engine embedded.

| Build                                                               | On-disk (build-stripped)      |
|---------------------------------------------------------------------|-------------------------------|
| **ReleaseSafe `-Dwasm`** — the release build, the shipped artifact | **8.14 MB** (8,141,512 bytes) |

Measured with Zig 0.16.0 for `aarch64-macos`, re-measured **2026-09-14** on
the CI reference leg (the `size_claims` gate prints the built size).

Every `<N> MB` figure in this file, in `README.md`, and in `docs/landscape.md`
is checked against the freshly built binary by the `size_claims` gate
(`scripts/binary_size_report.sh --check`, wired into `test/run_all.sh`). A
figure that is deliberately *not* the shipped size carries an inline
`<!--size:other-->` marker so the exemption is explicit rather than silent.
This is the structural answer to the rot this file itself carried until
2026-08-04, when the table said 6,974,584 bytes while the prose two paragraphs
below still quoted 3,240,000 and 3,820,664 from a pre-campaign build.

**As of O-008, `build.zig` strips the symbol table from every non-Debug build**
(`.strip = optimize != .Debug`) — so the *installed* `zig-out/bin/cljw` is the
shipped artifact directly, with no separate packaging step. cljw renders error
traces from its own runtime stack, not native symbols, so stripping costs no
diagnostics; Debug stays unstripped for `lldb`.

**ReleaseSafe is the release build** — optimised *with* runtime safety checks
retained. `ReleaseSmall` builds smaller but turns safety checks off and is not
shipped; it is a size-floor reference only, and its figures are not gated
because they are not what anyone downloads. <!--size:other-->

### Growth history

| Date       | Bytes     | Note                                                                                                                                                                                                     |
|------------|-----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-07-16 | 9,469,816 | before the ADR-0172 binary-size campaign                                                                                                                                                                 |
| 2026-07-16 | 6,974,584 | after the campaign (−26.3% in one pass)                                                                                                                                                                  |
| 2026-08-04 | 7,368,808 | before the core_meta regeneration                                                                                                                                                                        |
| 2026-08-04 | 7,549,512 | core_meta.clj went 291 → 628 rows (ADR-0181); +180,704 B buys documentation for 326 more `clojure.core` vars, including `reduce` / `assoc` / `conj` / `first`. |
| 2026-09-14 | 8,141,512 | current — the embedded engine moved from zwasm v2.6.0 to v2.7.0 (plus two cljw-found fixes); +592,000 B is the engine's cross-module composition and observability hooks. 658 KB of headroom under the ceiling. |

The ADR-0172 campaign levers were: unwind-table strip (O-052), envelope-v7
constant pool + flate regions/sources (ADR-0173), zwasm v2.2.1 thunk collapse,
and sort dedup (O-053). The per-component budget plus this gate now govern
growth; the ADR-0172 derived ceiling is 8,800,000 bytes, and crossing it
requires a conscious budget amendment, not a silenced check.

What sits inside that binary: a full Clojure numeric tower (Long→BigInt
promotion, Ratio, BigDecimal), MVCC software transactional memory, agents,
futures/promises/delays, lazy + chunked sequences, transducers,
protocols/records/multimethods, namespaces, a CIDER-compatible nREPL, ~24
bundled `clojure.*` standard namespaces, both a tree-walking interpreter and a
bytecode VM — and the embedded zwasm engine (interpreter + JIT), which is
roughly 3 MB of that total on its own. <!--size:other-->

## Cold start (secondary, machine-dependent)

End-to-end `cljw -e nil` (process spawn + runtime init + eval), measured on the
ReleaseSafe build with [`hyperfine`](https://github.com/sharkdp/hyperfine) `-N`
on an Apple M4 Pro (re-measured 2026-07-16, the `-Dwasm` shipped config):

```
≈ 6 ms (6.3 ms ± 0.5 mean), warm filesystem cache
```

This includes loading the AOT-compiled `clojure.core` bootstrap (ADR-0056), so
it is the real time-to-first-eval a user experiences. It is not a stable
cross-machine number — reproduce it on your own hardware with the script above.

## Honesty note

These figures supersede earlier, rougher estimates. The binary grew as the
numeric tower, STM, agents, nREPL, protocols, the bundled `clojure.*`
namespaces, and finally the always-embedded Wasm engine landed. The point was
never a size record — it is that a from-scratch Clojure runtime with this much
of the language, plus a spec-complete WebAssembly engine, ships as a single
binary that starts in a few milliseconds.

What the honesty note used to say, and why it is worth recording: it claimed
"~3.4 MB (ReleaseSafe) is the honest current size" <!--size:other-->, a figure
from before the Wasm engine was embedded by default. A number that no gate
checks will drift from the truth and then be quoted as if it were measured.
That is why the `size_claims` gate now reads this file too — and why it caught
this very sentence on its first run.
