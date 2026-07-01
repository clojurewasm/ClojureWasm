# Read-only reference clones

These paths appear in `.claude/settings.json` `additionalDirectories`.
Never edit or commit from them. Code reading only.

## Primary references (cw lineage)

- **cw v0** — git tag `v0.5.0` (89K LOC). NOT in `main`'s tree (the `-s ours`
  redesign merge kept the redesign tree), so reach it through git rather than a
  live path: `git worktree add ../cw-v0 v0.5.0`, or `git show v0.5.0:<path>`.
  - Use: feature contrast, interop boundary inspection, audit reference for known pain points
  - NOT to copy verbatim (per `.claude/rules/no_copy_from_v1.md`)
- `~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref/` — **Phase 1+2 reference**
  - Use: previous re-design attempt; diff against current cw v1

## Upstream sources (semantics ground truth)

- `~/Documents/OSS/clojure/` — **JVM Clojure source**
  - Use: canonical semantics for each var; ground truth for Tier A behavior
  - Focus paths: `src/jvm/clojure/lang/*.java` (Compiler, RT, Var, IFn, Numbers, PersistentVector, PersistentHashMap, LazySeq, MultiFn, Atom, LockingTransaction, Ref, Reflector), `src/clj/clojure/core.clj`
- `~/Documents/OSS/babashka/` — **Babashka (SCI-based subset Clojure)**
  - Use: precedent for JVM-independent Clojure execution; understand what was deliberately omitted
- `~/Documents/OSS/spec.alpha/` — **clojure.spec.alpha**
  - Use: Phase 6 spec implementation reference
- `~/Documents/OSS/openjdk24/` — **OpenJDK 24 source**
  - Use: JVM internals reference for memory model, GC, lock, concurrent primitives. Read when designing cw equivalents.

## Executable oracle — real Clojure (`clj`)

**`clj` is installed and is the first-class input→output differential
oracle** (`/opt/homebrew/bin/clj`, Clojure CLI 1.12.x). Per F-011, the
loop verifies behavioural equivalence against real Clojure rather than
guessing expected output — **including error cases**.

```sh
timeout 20 clj -M -e '<expr>'            # ground-truth value (ALWAYS timeout-wrap)
timeout 20 clj -M -e '<expr>' 2>&1 | grep -oE '\(([A-Za-z]+Exception|[A-Za-z]+Error)\)'  # error class
```

- **ALWAYS `timeout`-wrap the oracle.** `clojure.main -e` *prints* its
  result, so probing an **infinite lazy seq** (`(iterate inc 0)`,
  `(range)`, `(repeat 1)`, `(cycle [1])`, `(line-seq …)`) realises it
  **forever** — a JVM pinned at ~160 % CPU. If the parent session dies it
  re-parents to PID 1 and the `cleanup_orphans.sh` SessionStart hook does
  **not** reap `java`/`clj` (only zig/cljw/orb/grep), so it survives for
  hours and drives host load past 40 (2026-05-31 incident: a `(iterate
  inc 0)` orphan held 1.6 cores for 60 min, garbling the tool channel).
  `timeout 20` makes the probe self-terminate. Never run a bare `clj -M
  -e` on a sequence-producing form — bound it (`(take 5 …)`) **and**
  timeout-wrap it. See `.claude/rules/orphan_prevention.md` § The rules (rule 2).
- **Use**: when probing a behaviour, run it through `clj` to get the
  canonical output; diff against `zig-out/bin/cljw -e '<expr>'`.
- **Error-case caveat**: the message FORMAT differs (cljw renders its
  own `[kind]` header; `clj` renders `Execution error (<Class>) at
  user/eval… \n <message>`). The **exception CLASS** and the **value**
  must match; the surrounding format need not. Extract the class with
  the grep above.
- **Cost**: `clj` startup is ~1–2 s/call — batch probes; do not call it
  per-element in a loop.
- **Deliberate divergences** (recorded in ADRs) are NOT oracle
  failures: e.g. `(class 5)` prints `Long` in cljw vs `java.lang.Long`
  in `clj` (no-JVM rule). The oracle flags a mismatch; the loop decides
  whether it is a real defect or a recorded surface divergence.
- **Tracked sweep state (the resume SSOT)**: `test/diff/clj_corpus/COVERAGE.md`
  (swept areas / next candidates / acceptable divergences) + the golden
  corpora beside it. Harness: `scripts/clj_diff_sweep.sh` per
  `.claude/rules/clj_diff_sweep.md`. Gitignored running scratch (optional, NOT
  load-bearing): `private/notes/phaseA26-clj-differential-oracle.md`.

This is the executable form of `~/Documents/OSS/clojure/` (the source).
Read the source for *why*; run `clj` for *what*.

## Reference WASM stacks

- `~/Documents/OSS/wasmtime/` — **wasmtime (Rust)**
  - Use: WebAssembly runtime reference (Phase 16+ Pod boundary design)

## Quality-elevation corpora (interim-goal re-cut, 2026-05-29)

These feed the post-milestone quality loop (run real-world / posted
Clojure code through cljw, root-cause every divergence, refactor
rather than workaround). Wired for future Phase use; not yet
consumed. See the planning note `private/notes/recut-goal-synthesis.md`
+ the strategy ADR/F-NNN landed alongside it.

- `~/Documents/OSS/clojure-corpus/` — **200+ real-world Clojure
  libraries**, 22 categories (`01_clojure_official` … `22_debug_profile`),
  ~8.5K `.clj`/`.cljc` files, shallow-cloned 2026-05-22 (`MANIFEST.md`
  + `clone_all.sh`). Use: load real libraries through cljw, extract
  JVM-feature usage patterns, drive coverage gap closure. Pure-Clojure
  subsets first (data.json, tools.reader, core.match, math.*),
  Java-interop-heavy ones (jdbc, jackson-backed json) later/never.
  Note: `02_clojurescript_core` is empty (clone incomplete) — re-run
  `clone_all.sh` for missing categories when the loop reaches them.
- `~/Documents/OSS/clojuredocs-export-edn/` — **ClojureDocs posted
  code-example corpus** as EDN (`exports/export.compact.min.edn`,
  ~1.9 MB; ~1528 vars carry non-nil `:examples`). Each entry:
  `{:ns :name :arglists :doc :see-alsos :examples [<code strings>]}`.
  Use: differential-vs-JVM test fuel — run each example through cljw
  and (where available) JVM Clojure, compare, root-cause every
  mismatch. Refresh by `git pull` (upstream re-exports daily).

## Pattern libraries (optional learning)

- `~/Documents/OSS/zig/` — **Zig stdlib source**
  - Use: Zig 0.16 idiom confirmation, std.Io abstraction design, std.atomic / std.Thread API verification
- `~/Documents/OSS/malli/` — **Malli (Clojure schema library)**
  - Use: schema validation pattern reference (Phase 11+ comparison)
- `~/Documents/OSS/mattpocock_skills/` — TypeScript / typing learning material
  - Use: type system design reference (secondary)

## Perf-reference clones (clone reference impls freely for a perf lever)

For the "beat Python on every bench" campaign (memory
`perf-beat-python-every-bench`), the reference implementation of any slow
primitive may be **cloned into `~/Documents/OSS/` and studied** to design a
Zig-native equivalent-but-faster path (user direction 2026-06-15 — explicit
approach flexibility, not just for regex). Re-derive, never copy verbatim.

- **Regex** (the `35_regex_count` loser; ADR-0147 = the perf approach): the
  closest blueprint is **`~/Documents/OSS/ezi-gex/`** (cloned 2026-06-15) — a Zig
  Thompson-NFA engine with the EXACT technique stack cljw wants (Literal Prefilter
  + Lazy/Eager DFA + Teddy SIMD + zero-alloc). **Targets Zig 0.17.0-dev — will NOT
  compile on stable 0.16**, so it is a *source blueprint, not a dependency*; the
  applicable files are `src/engine/{memmem,teddy,simd,redos}.zig` +
  `src/engine/backends/{literal,dfa,edfa,pikevm,auto}.zig`. Also: `openjdk24/`
  java.util.regex (`BnM` Boyer-Moore prefilter); burntsushi `regex-internals` blog +
  Rust `regex-automata` (the authoritative meta-engine); clone **CPython `_sre`**
  (`SRE_OP_LITERAL` prefix scan) / **google/re2** (lazy-DFA, refuses backrefs like
  cljw) on demand. Borrow the ALGORITHM, re-derive in cljw's Pike-NFA + Zig 0.16;
  the 48-golden `regex_equivalence` corpus is the F-011 proof. Cross-lang
  equivalence audit DONE (ADR-0145 gate); profile each lever (the gap is the
  matcher walk + per-match alloc, not recompilation — `#"…"` compiles once).
- **General**: for nested_update (persistent HAMT update path), bigint
  (multiplication algorithm), etc., the JVM (`openjdk24/`) + cw v0 + the
  relevant OSS lib are the textbooks. Clone what is missing when the lever opens.

## Reading discipline

At each Phase Step 0 (textbook_survey):
1. Read JVM Clojure source for canonical behavior
2. Read cw v0 for "how v0 handled this"
3. Read Babashka for "what subset works without JVM"
4. Cite explicit references in per-task notes and ADRs

NEVER copy code verbatim from these references (per `no_copy_from_v1.md`).
Re-derive semantics from understanding.
