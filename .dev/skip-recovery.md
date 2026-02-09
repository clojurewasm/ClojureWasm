# SKIP Recovery Plan

Master plan for recovering implementable vars from the 165 SKIP status vars.

**Stats**: 165 skip → ~50 to recover, ~85 permanently JVM, ~30 deferred

## Summary

| # | Category              | Vars | Decision         | Target Phase |
|---|-----------------------|------|------------------|--------------|
| 1 | Java Array ops        | 35   | IMPLEMENT        | 43           |
| 2 | Agent (concurrency)   | 17   | DEFER            | —            |
| 3 | STM / Ref             | 9    | OUT OF SCOPE     | —            |
| 4 | Proxy/Reify/Deftype   | ~20  | PARTIAL (5 vars) | 42           |
| 5 | Future                | 9    | IMPLEMENT        | 44           |
| 6 | import → wasm mapping | 2    | DESIGN EXPLORE   | 45           |
| 7 | BigDecimal/Ratio      | 7    | IMPLEMENT        | 43           |
| 8 | Quick wins            | ~10  | IMPLEMENT        | 42           |

Phase order: 42 → 43 → 44 → 45

---

## Category 1: Java Array Operations (35 vars) — Phase 43

**Decision**: IMPLEMENT — new Array Value type in Zig.

**Vars**:
```
aclone, aget, alength, amap, areduce, aset,
aset-boolean, aset-byte, aset-char, aset-double,
aset-float, aset-int, aset-long, aset-short,
boolean-array, byte-array, bytes, char-array, chars,
double-array, doubles, float-array, floats,
int-array, ints, into-array, long-array, longs,
make-array, object-array, short-array, shorts,
to-array, to-array-2d
```

**Approach**:
- New NanHeapTag for Array (typed mutable container)
- Single Zig array type covering int/float/object
- `aget`/`aset` as Zig builtins (Tier 1)
- `amap`/`areduce` as core.clj macros (Tier 2)
- Typed constructors (`int-array`, `byte-array`, etc.) as Zig builtins

**Dependencies**: New Value variant (D## decision needed)

---

## Category 2: Agent Concurrency (17 vars) — DEFERRED

**Decision**: DEFER — requires multi-thread GC safety, complex interaction
with dynamic bindings. Revisit after Future (Phase 44).

**Vars**:
```
agent, agent-error, agent-errors, await, await-for,
await1, clear-agent-errors, release-pending-sends,
restart-agent, send, send-off, send-via,
set-agent-send-executor!, set-agent-send-off-executor!,
set-error-handler!, set-error-mode!, shutdown-agents
```

**Notes**: `*agent*` dynamic var also skipped. Requires F6 (multi-thread bindings).

---

## Category 3: STM / Ref (9 vars) — OUT OF SCOPE

**Decision**: OUT OF SCOPE — atom provides sufficient concurrency primitive.
STM requires multi-thread shared memory model not applicable to Zig/Wasm target.

**Vars**:
```
alter, commute, dosync, ref, ref-history-count,
ref-max-history, ref-min-history, ref-set, sync
```

**Notes**: Permanent skip. Atom + volatile cover all practical use cases.

---

## Category 4: Proxy/Reify/Deftype (~20 vars) — PARTIAL

**Decision**: Implement protocol extension API only (5 vars in Phase 42).
Class-system vars (proxy, reify, deftype, gen-class) permanently skipped.

**Implement (Phase 42)**:
```
extend, extenders, extends?, satisfies?, find-protocol-impl
```

**Permanent skip** (JVM class system):
```
deftype, definterface, gen-class, gen-interface,
get-proxy-class, init-proxy, proxy, proxy-call-with-super,
proxy-mappings, proxy-name, proxy-super, reify,
update-proxy, deftype*, reify*, supers, bases
```

**Approach**: `extend` enables runtime protocol extension (map-based dispatch).
CW already uses fn dispatch for protocols; extend adds dynamic extension.

---

## Category 5: Future (9 vars) — Phase 44

**Decision**: IMPLEMENT — Zig std.Thread + thread pool.

**Vars**:
```
future, future-call, future-cancel, future-cancelled?,
future-done?, future?, pcalls, pmap, pvalues
```

**Approach**:
- New Future Value type (NanHeapTag)
- Zig `std.Thread` thread pool
- `deref` with timeout support
- GC safety: pin values across thread boundary
- `pmap` via future + chunked dispatch

**Dependencies**: F6 (multi-thread bindings), GC thread safety

---

## Category 6: import → Wasm Mapping (2 vars) — Phase 45

**Decision**: DESIGN EXPLORE — research ClojureDart-like :import model.

**Vars**:
```
import, import*
```

**Approach**: Currently ns :import is a no-op stub. Research mapping
Java-style import to wasm module loading. May require new :wasm-import
syntax or repurposing :import for .wasm modules.

**Reference**: ClojureDart import model, cljw.wasm namespace

---

## Category 7: BigDecimal / Ratio (7 vars) — Phase 43

**Decision**: IMPLEMENT — pure Zig arbitrary precision.

**Vars**:
```
bigdec, bigint, biginteger, denominator, numerator,
rationalize, with-precision
```

**Approach**:
- BigInt: pure Zig arbitrary precision integer (no external deps)
- BigDecimal: BigInt + scale
- Ratio: BigInt numerator/denominator pair (extends F3)
- New NanHeapTag(s) for BigInt, BigDecimal, Ratio
- Arithmetic dispatch: extend existing +/-/*/div

**Dependencies**: F3 (Ratio type), F131 (BigInt), F132 (Ratio)

---

## Category 8: Quick Wins (~10 vars) — Phase 42

**Decision**: IMPLEMENT — straightforward, no new type system work.

**Vars**:
```
with-in-str        — core.clj macro (binding *in* (StringReader.))
uri?               — Zig builtin predicate
uuid?              — Zig builtin predicate
destructure        — core.clj fn (upstream verbatim)
seq-to-map-for-destructuring — core.clj helper
bytes?             — Zig builtin predicate (type check)
bound-fn, bound-fn* — dynamic binding capture
get-thread-bindings — current binding frame access
```

**Also consider**:
```
definline          — compiler macro (low priority)
read, read+string  — needs PushbackReader (may defer)
```

**Approach**: Mix of core.clj (Tier 2) and Zig builtins (Tier 1).
No new Value types needed.

---

## Permanent Skip (not recovering)

These vars are permanently skipped due to JVM class system dependency:

- **Struct system** (deprecated): `accessor`, `create-struct`, `defstruct`,
  `struct`, `struct-map`
- **Class/type introspection**: `supers`, `bases`, `class?`
- **Java interop operators**: `.`, `..`, `new`, `memfn`
- **Compilation**: `compile`, `*compile-path*`
- **Classloader**: `*fn-loader*`, `*use-context-classloader*`, `add-classpath`,
  `with-loading-context`
- **IO handle types**: `input-stream`, `output-stream`, `reader`, `writer`,
  `make-input-stream`, `make-output-stream`, `make-reader`, `make-writer`,
  `as-url`, `default-streams-impl`
- **Print dispatch**: `print-dup`, `print-method`, `print-simple`, `print-ctor`,
  `PrintWriter-on`
- **Threading/monitoring**: `monitor-enter`, `monitor-exit`, `io!`, `locking`
  (already done as macro), `seque`
- **Misc JVM**: `bean`, `enumeration-seq`, `iterator-seq`, `resultset-seq`,
  `vector-of`, `primitives-classnames`, `method-sig`
- **Internal**: `->ArrayChunk`, `->Eduction`, `->Vec`, `->VecNode`, `->VecSeq`,
  `-cache-protocol-fn`, `-reset-methods`, `EMPTY-NODE`,
  `StackTraceElement->vec`

---

## Phase Timeline

```
Phase 42: Quick Wins + Protocol Extension
  ├── 42.1: Quick wins (with-in-str, uri?, uuid?, destructure, bytes?)
  ├── 42.2: Protocol extension API (extend, extenders, extends?)
  └── 42.3: Remaining implementable core vars

Phase 43: Numeric Types + Arrays
  ├── 43.1: BigInt (pure Zig arbitrary precision)
  ├── 43.2: BigDecimal
  ├── 43.3: Ratio type (F3/F132)
  ├── 43.4: Array Value type + core ops
  └── 43.5: Typed array constructors + utilities

Phase 44: Concurrency Primitives
  ├── 44.1: Thread pool infrastructure (Zig)
  ├── 44.2: future, future-call, deref timeout
  ├── 44.3: pmap, pcalls, pvalues
  └── 44.4: bound-fn, get-thread-bindings

Phase 45: import Design Research
  ├── 45.1: Research: ClojureDart :import model
  ├── 45.2: Design: map Java import to wasm module loading
  └── 45.3: Implementation (if design viable)
```

**References**:
- `.dev/roadmap.md` — Phase definitions
- `.dev/checklist.md` — F130-F135
- `.dev/status/vars.yaml` — Per-var status tracking
