# Read-only reference clones

Never edit or commit from these paths. Code reading only.

None of them ships with the repo, and none is resident on the current
maintainer machine: every `~/Documents/OSS/<name>` row below is a recipe
(clone it, then read it). To let a Claude Code session read a clone outside
the worktree, list it under `permissions.additionalDirectories` in your own
gitignored `.claude/settings.local.json`; the tracked `.claude/settings.json`
lists none. `scripts/check_reference_clones.sh` holds every row to that
contract once `~/Documents/OSS` exists.

## Primary references (cw lineage)

- **cw v0** — git tag `v0.5.0` (89K LOC). NOT in `main`'s tree (the `-s ours`
  redesign merge kept the redesign tree), so reach it through git rather than a
  live path: `git worktree add ../cw-v0 v0.5.0`, or `git show v0.5.0:<path>`.
  - Use: feature contrast, interop boundary inspection, audit reference for known pain points
  - NOT to copy verbatim (memory `20260909235201-14470f53`, no_copy_from_v1)

## Upstream sources (semantics ground truth)

- `~/Documents/OSS/clojure/`: **JVM Clojure source** <!--ref:on-demand-->
  - `git clone --depth 1 https://github.com/clojure/clojure ~/Documents/OSS/clojure`
  - Use: canonical semantics for each var; ground truth for Tier A behavior
  - Focus paths: `src/jvm/clojure/lang/*.java` (Compiler, RT, Var, IFn, Numbers, PersistentVector, PersistentHashMap, LazySeq, MultiFn, Atom, LockingTransaction, Ref, Reflector), `src/clj/clojure/core.clj`
- `~/Documents/OSS/babashka/`: **Babashka (SCI-based subset Clojure)** <!--ref:on-demand-->
  - `git clone --depth 1 https://github.com/babashka/babashka ~/Documents/OSS/babashka`
  - Use: precedent for JVM-independent Clojure execution; understand what was deliberately omitted
- `~/Documents/OSS/spec.alpha/`: **clojure.spec.alpha** <!--ref:on-demand-->
  - `git clone --depth 1 https://github.com/clojure/spec.alpha ~/Documents/OSS/spec.alpha`
  - Use: Phase 6 spec implementation reference
- `~/Documents/OSS/openjdk24/` — **OpenJDK 24 source** <!--ref:on-demand-->
  - Use: JVM internals reference for memory model, GC, lock, concurrent primitives. Read when designing cw equivalents.
  - Not resident (multi-GB). `git clone --depth 1 https://github.com/openjdk/jdk ~/Documents/OSS/openjdk24`

## Executable oracle — real Clojure (`clj`)

**`clj` (the Clojure CLI) is the first-class input→output differential
oracle.** It is resolved from `PATH` (`scripts/harness/process.clj` runs `clj`,
`scripts/lib_conformance.sh` honours `CLJ=<path>`); install it per
<https://clojure.org/guides/install_clojure>. The oracle tools need it, the gate
does not. Per F-011, the
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
  re-parents to PID 1, where `scripts/cleanup_orphans.sh` only catches it at
  the NEXT session start and only after 30 minutes — long enough to drive host
  load past 40 in the meantime (2026-05-31 incident: a `(iterate inc 0)` orphan
  held 1.6 cores for 60 min, garbling the tool channel).
  `timeout 20` makes the probe self-terminate. Never run a bare `clj -M
  -e` on a sequence-producing form — bound it (`(take 5 …)`) **and**
  timeout-wrap it. See memory `20260909234832-598b7c16` (orphan_prevention), rule 2.
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
  corpora beside it. Harness: `bb scripts/clj_diff_sweep.clj` per memory
  `20260909234815-3490bbcd` (clj_diff_sweep). Any `private/notes/` file cited
  near it is per-developer scratch, gitignored and absent from a clone.

This is the executable form of the JVM Clojure source listed above.
Read the source for *why*; run `clj` for *what*.

## Reference WASM stacks

- `~/Documents/OSS/wasmtime/` — **wasmtime (Rust)** <!--ref:on-demand-->
  - Use: WebAssembly runtime reference (Phase 16+ Pod boundary design)
  - Not resident (multi-GB). `git clone --depth 1 https://github.com/bytecodealliance/wasmtime ~/Documents/OSS/wasmtime`
  - For Component Model / Canonical ABI questions the FIRST reference is zwasm
    itself, tag-pinned into `build.zig.zon` — it is the implementation cljw
    actually runs on. Upstream is <https://github.com/zwasm/zwasm> (its own org
    since 2026-08-12, separate maintainership); a local clone of it, if present,
    is read-only reference like everything else in this file.

## Quality-elevation corpora (interim-goal re-cut, 2026-05-29)

These feed the post-milestone quality loop (run real-world / posted
Clojure code through cljw, root-cause every divergence, refactor
rather than workaround). Wired for future Phase use; not yet
consumed. The strategy is the F-NNN landed alongside it (its planning note
lived in the gitignored `private/notes/` and is not in a clone).

- A `clojure-corpus/` directory under `~/Documents/OSS`: **200+ real-world Clojure
  libraries**, 22 categories (`01_clojure_official` … `22_debug_profile`),
  ~8.5K `.clj`/`.cljc` files, shallow-cloned 2026-05-22 (`MANIFEST.md`
  + `clone_all.sh`). It was assembled on the upstream author's machine, and
  this repo records no public source for it; rebuild an equivalent from the
  libraries `test/conformance/verified_projects/` names. Use: load real
  libraries through cljw, extract
  JVM-feature usage patterns, drive coverage gap closure. Pure-Clojure
  subsets first (data.json, tools.reader, core.match, math.*),
  Java-interop-heavy ones (jdbc, jackson-backed json) later/never.
  Note: `02_clojurescript_core` is empty (clone incomplete) — re-run
  `clone_all.sh` for missing categories when the loop reaches them.
- `~/Documents/OSS/clojuredocs-export-edn/` — **ClojureDocs posted
  code-example corpus** as EDN <!--ref:on-demand-->
  (`git clone --depth 1 https://github.com/clojure-emacs/clojuredocs-export-edn ~/Documents/OSS/clojuredocs-export-edn`;
  `exports/export.compact.min.edn`,
  ~1.9 MB; ~1528 vars carry non-nil `:examples`). Each entry:
  `{:ns :name :arglists :doc :see-alsos :examples [<code strings>]}`.
  Use: differential-vs-JVM test fuel — run each example through cljw
  and (where available) JVM Clojure, compare, root-cause every
  mismatch. Refresh by `git pull` (upstream re-exports daily).

## Pattern libraries (optional learning)

- **Zig stdlib source** — `$(zig env | grep std_dir)`, i.e. the stdlib of the
  toolchain `flake.nix` pins. `zig env` prints it as `.std_dir`; the path is
  per-install, so this file does not name one.
  - Use: Zig 0.16 idiom confirmation, std.Io abstraction design, std.atomic / std.Thread API verification
  - Deliberately not a clone. A checkout tracks whatever branch it was cloned
    at, and the one this file used to name was post-0.16 master — ADR-0090
    §Context records a survey misled by exactly that skew. The toolchain's own
    stdlib is version-exact by construction and present on every machine that
    can build the project.
- `~/Documents/OSS/malli/`: **Malli (Clojure schema library)** <!--ref:on-demand-->
  - `git clone --depth 1 https://github.com/metosin/malli ~/Documents/OSS/malli`
  - Use: schema validation pattern reference (Phase 11+ comparison)
- `~/Documents/OSS/mattpocock_skills/`: TypeScript / typing learning material <!--ref:on-demand-->
  - `git clone --depth 1 https://github.com/mattpocock/skills ~/Documents/OSS/mattpocock_skills`
  - Use: type system design reference (secondary)

## Perf-reference clones (clone reference impls freely for a perf lever)

For the "beat Python on every bench" campaign (memory
`perf-beat-python-every-bench`), the reference implementation of any slow
primitive may be **cloned into `~/Documents/OSS/` and studied** to design a
Zig-native equivalent-but-faster path (user direction 2026-06-15 — explicit
approach flexibility, not just for regex). Re-derive, never copy verbatim.

- **Regex** (the `35_regex_count` loser; ADR-0147 = the perf approach) <!--ref:on-demand-->: the
  closest blueprint is **ezi-gex** (`git clone --depth 1
  https://github.com/shaik-abdul-thouhid/ezi-gex ~/Documents/OSS/ezi-gex`), a Zig
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

NEVER copy code verbatim from these references (memory
`20260909235201-14470f53`, no_copy_from_v1).
Re-derive semantics from understanding.
