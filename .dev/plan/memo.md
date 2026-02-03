# ClojureWasm Development Memo

## Current State

- Phase: 15 (Test-driven core library expansion)
- Roadmap: .dev/plan/roadmap.md
- Current task: (none)
- Task file: N/A
- Last completed: T15.3 — Namespace separation (D54: walk, template)
- Blockers: none
- Next: T15.4 — Port clojure_walk.clj (walk, postwalk, prewalk)

### Phase 15 Task Queue

Port high-priority test files from `.dev/notes/test_file_priority.md` Batch 1.
One test file = one task. TDD: port test → fail → implement → pass.

| Task  | File                | Focus                      |
| ----- | ------------------- | -------------------------- |
| T15.1 | macros.clj          | ->, ->>, threading macros  |
| T15.2 | special.clj         | let, letfn, quote, var, fn |
| T15.3 | namespace refactor  | D54: walk, template files  |
| T15.4 | clojure_walk.clj    | walk, postwalk, prewalk    |
| T15.5 | clojure_set.clj     | union, intersection, diff  |
| T15.6 | string.clj          | clojure.string tests       |
| T15.7 | keywords.clj        | keyword ops                |
| T15.8 | other_functions.clj | identity, fnil, constantly |
| T15.9 | metadata.clj        | meta, with-meta            |

## Long-term Reference (DO NOT DELETE until core library stabilizes)

### Test Porting Policy — JVM Dependency Handling

When porting tests from `test/clojure/test_clojure/`, follow these rules.
**Do NOT simply skip Java-dependent tests** — extract the intent and write equivalent tests.

#### JVM Dependency Categories

| Category         | Examples                       | Action                                |
| ---------------- | ------------------------------ | ------------------------------------- |
| Direct InterOp   | `.method`, `Class/static`      | Write equivalent test without Java    |
| Java Types       | `BigDecimal`, `Ratio`, `^long` | Test with ClojureWasm types only      |
| Exceptions       | `IllegalArgumentException`     | Test with ex-info/ex-data instead     |
| Threading        | `future`, `agent`, `pmap`      | Skip + record as F##                  |
| Java Collections | `into-array`, `aget`           | Skip (no equivalent)                  |
| Class Loader     | `compile`, `import`            | Partial test (basic require/use only) |
| Reflection       | `supers`, `bases`              | Skip (JVM-specific)                   |
| Implicit JVM     | overflow, interning            | Write explicit behavior tests         |

#### Porting Rules

1. **Read the test intent** — what behavior is being verified?
2. **Write equivalent test** — same intent, no Java dependency
   ```clojure
   ;; Original (JVM)
   (is (= 5 (.length "hello")))
   ;; Equivalent (ClojureWasm)
   (is (= 5 (count "hello")))
   ```
3. **Record skips with F## and reason**
   ```clojure
   ;; SKIP: F## - requires Java threading (agent)
   ;; Original: (is (= @(agent 0) 0))
   ```
4. **Document partial ports**
   ```clojure
   ;; PARTIAL: 12/20 assertions ported
   ;; SKIP: 8 assertions (BigDecimal, Thread)
   ```

#### Implicit JVM Assumptions (easy to miss)

| Pattern                | JVM Behavior       | ClojureWasm           |
| ---------------------- | ------------------ | --------------------- |
| `(instance? String x)` | Java class check   | Use `(string? x)`     |
| `(class [])`           | Returns Java class | Returns type keyword  |
| `(type 1)`             | `java.lang.Long`   | `:integer`            |
| `(hash x)`             | JVM hashCode       | Own impl (may differ) |
| `(identical? x y)`     | JVM reference eq   | Own impl              |

#### Reference Files

- `.dev/notes/test_file_priority.md` — prioritized file list
- `.dev/status/compat_test.yaml` — test tracking
- `.dev/checklist.md` — F## deferred items

#### Root Cause Resolution Policy

**Goal**: Run upstream tests and .clj implementations **unmodified**.

**When tests fail or bugs appear:**

1. Investigate the root cause fully
2. Fix the implementation (.zig or .clj) or implement missing features
3. If fixing reveals additional bugs, fix those too
4. Never work around implementation gaps by modifying tests

**Upstream .clj files:**

- Use upstream source verbatim whenever possible
- If modification is unavoidable, add `UPSTREAM-DIFF:` comment explaining why
- Check "Zig Implementation First" policy before deciding something is impossible

**Test modifications:**

- Only allowed for truly JVM-specific code with no portable equivalent
- Add SKIP comment with F## reference and clear reason
- Exhaust all implementation options before skipping

---

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 15 Core Policies

**1. Namespace Compatibility**

Maintain namespace compatibility with upstream Clojure. Functions temporarily
placed in `core.clj` for bootstrap order (e.g., walk functions) should be
moved to their proper namespaces.

- `clojure.walk` → walk, prewalk, postwalk, etc.
- `clojure.set` → union, intersection, difference, etc.
- `clojure.string` → split, join, trim, etc.

When test porting reveals namespace mismatches, fix them on the spot.

**2. Zig Implementation First**

Do NOT skip features just because they appear "JVM-specific". Evaluate in order:

1. **Zig-implementable** — defrecord, defmethod, sorted-set-by, etc.
   ClojureWasmBeta has proven Zig implementations. Implement with behavioral equivalence.

2. **Pure Clojure implementable** — in core.clj or namespace-specific .clj files

3. **Skip** — only truly JVM-specific features (Java threading, reflection, etc.)

Before marking something as "JVM-dependent", check if Zig/Clojure implementation
is possible. Refer to ClojureWasmBeta for guidance when uncertain.

### Phase 15 Starting Point

- vars.yaml: 269 done, 428 todo, 7 skip (total 704)
- Test coverage: 72 tests, 267 assertions (TreeWalk)
- compat_test.yaml: 178 tests tracked

### Test File Locations

- Upstream tests: `/Users/shota.508/Documents/OSS/clojure/test/clojure/test_clojure/`
- Ported tests: `test/clojure/`
- Priority list: `.dev/notes/test_file_priority.md`

### Known Issues (carry forward)

- **VM SCI tests failure**: TreeWalk primary backend, VM tests low priority
- **F25/F26**: for macro :while and :let+:when — deferred
- **F58**: Nested map destructuring — workaround: sequential let bindings
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — deferred
