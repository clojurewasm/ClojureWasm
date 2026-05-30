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
- 2026-05-30: map generated + validated. P0 progress:
  - **DONE**: `hash`, `gensym` (35721849); `volatile!`/`vreset!`/`vswap!`/`volatile?` (e3281deb);
    `comparator` (this batch).
  - **DONE D-092** (vector keys by value): `keyEqValue`/`valueHash` recurse over vector elements,
    fixing `(frequencies [[1] [1] [2]])` → `{[1] 2, [2] 1}` + vector-keyed maps/sets/distinct.
    Residual: LIST / map / set keys + cross-type vec≡list keys still identity-compared.
  - **DONE**: `memoize` (96f9b857); **metadata** `meta`/`with-meta`/`vary-meta` over collections
    (the per-type `meta` field already existed; ArrayMap gained one; ops preserve meta) — substantially
    discharges D-075. Residuals: clojure.set project/rename wrap-restoration (live PROVISIONAL markers —
    a clean next follow-up now that with-meta exists), symbol meta, alter-meta!/reset-meta!, reader `^`.
  - **DONE**: clojure.set project/rename meta-wrap restored (4b3cee2e) → D-075 fully discharged bar
    symbol meta / alter-meta! / reset-meta! / reader `^`.
  - **sorted-map / sorted-set = persistent LLRB red-black tree** per **ADR-0057** (the Step-0.6 DA
    fork OVERTURNED the survey's flat-array on F-002: a flat array's O(n)-copy-on-assoc breaks
    structural-sharing + makes `(into (sorted-map) coll)` O(n²); "RB is hard" is the Cycle-budget-defer
    smell). `rb_node` tag (= renamed reserved_c11); set-wraps-sorted-map; default valueCompare
    (ADR-0053) + custom -by via callFn. New `runtime/collection/sorted.zig`; dispatch arms at
    collection.zig/sequence.zig/lookup.zig/print.zig.
    - **Cycle A — DONE**: RbNode struct + GC trace + valueCompare-ordered build / get / contains /
      count / keys / vals / seq / assoc / conj + `sorted-map`/`sorted-set` ctors + `sorted?` + print +
      IFn. 21-case e2e `phase14_sorted` green; gate 165/165. delete/-by/subseq raise/skeleton until B/C.
    - **Cycle B1 — DONE**: functional LLRB delete (dissoc/disj — Sedgewick moveRedLeft/moveRedRight/
      deleteMin). Strong canary: build-50-shuffled → delete-half → assert full LLRB invariants (BST
      order, left-lean, no consecutive reds, equal black-height) + drain-to-empty. 9 new e2e (30 total).
    - **Cycle B2 — DONE**: `sorted-map-by`/`sorted-set-by` custom comparators. Resolved the Layer-0
      callFn question by threading `env` through every comparing op (assoc/get/contains/dissoc/conjSet/
      setContains/disjSet + lookup.invoke + tree_walk:905), mirroring `multimethod.zig`'s established
      pattern. `compareKeys` calls `rt.vtable.callFn`; Boolean result = less-than predicate, numeric =
      sign (Clojure `AFunction.compare`). 8 new e2e (38 total); `>`/`<`/numeric/str-len comparators all
      green incl. get/disj/as-fn parity. **The env-threaded callFn-from-primitive pattern now unblocks
      D-159** (`(sort cmp coll)` 2-arg comparator) — same AFunction.compare logic.
    - **Cycle C1 — DONE**: `rseq` (Zig primitive, seq/count-style tag dispatch: vector reverse /
      sorted descending walk = left→node→right + prepend / empty→nil / non-reversible→type_error) +
      `reversible?` core.clj:736 flipped to `(or (vector? x) (sorted? x))`. 8 new e2e (46 total).
    - **Cycle C2 — DONE**: `subseq`/`rsubseq` (sorted range queries). Tree-walk in sorted.zig emits
      entry (pair for map / elem for set) filtered by `(test (compareKeys node-key bound) 0)` applied
      via callFn; both 3-arg `(sc test key)` and 5-arg `(sc s-test s-key e-test e-key)` forms; rsubseq =
      descending walk. Honors custom `-by` comparators. 9 new e2e (55 total). **sorted is now FULLY
      complete** (build/read/delete/`-by`/rseq/reversible?/subseq/rsubseq + print + IFn + GC).
  - **then**: **transducers** (HIGH ROI, BIG — survey-worthy: transducer protocol over reduce/reduced,
    1-arg HOF arities); MEDIUM fill-ins: `isa?`/hierarchy, `resolve`/ns (needs first-class var Value?),
    `bigint`/`bigdec` (LOW-med ROI + fiddly 5 coerce arms + string parsers — deprioritized).
  - **also found**: `(sort cmp coll)` comparator-arg = D-159; regex capture groups; `resolve` missing.
- **New gaps found while sweeping** (not yet chased): `(sort cmp coll)` with a 2-arg COMPARATOR fn
  errors — cljw `sort`'s 2-arg form treats the fn as a 1-arg key-fn, not a comparator (= **D-159**);
  regex capture groups unsupported ("cycle 1"); `resolve` itself missing (P2).
