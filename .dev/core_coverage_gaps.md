# clojure.core coverage gap map (corpus-driven, D-158 tier 1)

Unbiased functional-completeness work queue: the real `clojure.core`
public var list (babashka `ns-publics`, ~647) diffed against cljw's var
set. Replaces AI-probed guessing. Companion to D-158 (the later
clojuredocs-examples + real-library-test tiers).

## Regenerate

```sh
bb -e "(spit \"/tmp/core_vars.txt\" (clojure.string/join \"\n\" (sort (map name (keys (ns-publics 'clojure.core))))))"
# cljw var set = primitives ∪ core.clj defs ∪ macros ∪ special forms:
rg -oN '\.name = "[^"]+"' src/lang/primitive/ src/runtime/ src/lang/macro_transforms.zig | sed -E 's/.*"([^"]+)".*/\1/' | sort -u > /tmp/p
rg -oN '^\((def|defn|defmacro|definline|def-) [^ ()]+' src/lang/clj/clojure/*.clj | sed -E 's/^[^ ]*\([a-z-]+ //' | sort -u >> /tmp/p
rg -oN '\.\{ "[^"]+"' src/eval/analyzer/analyzer.zig | sed -E 's/.*"([^"]+)".*/\1/' >> /tmp/p
sort -u /tmp/p > /tmp/cljw_vars.txt
comm -23 /tmp/core_vars.txt /tmp/cljw_vars.txt   # = missing
```

Caveat: the static var-set extraction has minor false-positives (e.g.
`subvec` showed "missing" but works) — always confirm a gap with a real
`cljw -e` probe before implementing. bb's core ≈ JVM core (a few bb-only
/ JVM-only deltas).

## Priority clusters (validated by probe 2026-05-30)

### P0 — trivial / reuses existing infra (do first, batch)
- **hash** — expose `equal.valueHash` (already written for the HAMT). 1 primitive.
- **gensym** — expose `rt.gensym` (macros already use it). 1 primitive (0/1-arg).
- **volatile! / vreset! / vswap! / volatile?** — a mutable box like atom but
  no CAS/watch. Mirror `runtime/atom.zig` (or a `volatile` tag). High-value
  (transducers use volatiles).
- **comparator** — `(comparator pred)` → `(fn [a b] (cond (pred a b) -1 (pred b a) 1 :else 0))`. core.clj defn.
- **bigint / bigdec / biginteger** — wrap existing BigInt / BigDecimal. primitives.

### P1 — common, moderate
- **memoize** — `(memoize f)` over an atom-backed cache map. core.clj defn (needs atom — now present).
- **sorted-map / sorted-set / sorted-map-by / sorted-set-by / sorted? / subseq / rsubseq** —
  a sorted collection (tree). heap_tag slots reserved (C14 sorted_map etc.). New data structure (MEDIUM).
- **rseq** (reverse seq of vector/sorted) — needs reversible support.
- **metadata: with-meta / meta / vary-meta / alter-meta! / reset-meta!** — FOUNDATIONAL
  (value-model meta slot; investigate whether HeapHeader carries meta or a side-table is needed). Used everywhere.
- **transducers: transduce / sequence / eduction / completing / cat / halt-when / ensure-reduced / unreduced** —
  big feature (transducer protocol over the existing reduce/reduced). MEDIUM-HIGH.
- **trampoline** — core.clj defn (loop on fn results).

### P2 — type / hierarchy / var+ns introspection
- **isa? / ancestors / descendants / parents / derive / underive / make-hierarchy / global-hierarchy** — multimethod hierarchy.
- **type / class / class? / satisfies? / extends? / extenders** — type queries.
- **resolve / ns-resolve / requiring-resolve / find-var / intern / the-ns / find-ns / all-ns / create-ns /
  ns-name / ns-publics / ns-map / ns-aliases / ns-interns / ns-refers / ns-imports / ns-unmap / alias** —
  var/ns introspection (also unblocks a future resolve-based coverage harness).
- **eval / read / read-line / read+string / load-string / load-file / load-reader** — eval/read surface.

### Deferred / out-of-scope (NOT gaps to chase now)
- **Phase 15 (concurrency)**: agent / send / send-off / await / restart-agent / agent-error / shutdown-agents /
  dosync / commute / ensure / ref-set / alter / future-call / future-cancel / set-agent-* (D-117/118, ADR-0009/0010).
- **Tier D (JVM-class)**: proxy / proxy-super / gen-class(absent) / bean / definterface / reify(maybe wanted later).
- **Java arrays / interop (Tier C)**: aget / aset-* / aclone / alength / amap / areduce / make-array /
  X-array (boolean/byte/char/...) / Xs (bytes/ints/...) / to-array / into-array / object-array.
- **Perf primitives (low priority)**: unchecked-* family, chunk-* / chunked-seq? (chunking).
- **REPL / dynamic vars**: *1 *2 *3 *e *ns* *out* *err* *in* *print-* etc. — some (*out*/*err*/*ns*) matter; most are REPL-only.
- **Misc JVM**: PrintWriter-on, StackTraceElement->vec, enumeration-seq, iterator-seq, file-seq(partly), xml-seq,
  memfn, munge, system-time, add-tap/tap>/remove-tap.

## Status
- 2026-05-30: map generated + validated. Starting P0 batch (hash / gensym / volatile! / comparator / bigint).
