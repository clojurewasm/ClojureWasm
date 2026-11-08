# probes/testcheck — landing clojure.test.check on cljw (D-298)

Measurement scripts for the test.check rung. test.check is the generator engine
`malli.generator` sits on, so it gates every schema-driven property/mutation
suite (hive-schemas.test, hive-test.properties).

Run each with the freshly built binary:

    B=zig-out/bin/cljw
    $B .dev/probes/testcheck/<script>.clj

## Blockers, measured 2026-08-18 against v1.10.8

| # | Site | Symptom | State |
|---|---|---|---|
| 1 | `rose_tree.cljc:101` | `for` bound the ns's shadowed `seq` | FIXED — `coreSym`/`coreCall` |
| 2 | `random.clj:178` | `proxy` unresolved (`[ThreadLocal]`) | OPEN — D-298 |
| 3 | `properties.cljc:38` | `java.lang.ThreadDeath` not a known catch class | OPEN |
| 4 | `clojure_test.cljc:172` | `clojure.lang.MultiFn` unresolvable | OPEN |

## Scripts

- `hyg.clj` — the macro-hygiene repro. In a ns that `:refer-clojure :exclude`s
  `seq`, `(for [i (range 3)] (* i i))` must print `[0 1 4]`. Before the fix it
  raised `*: expected number, got nil`, i.e. it silently built a wrong program.
- `qual.clj` — proves `clojure.core/`-qualified heads resolve for both fns and
  macros even when the ns shadows the name. This is what makes the fix viable.
- `interop.clj`, `interop3.clj` — `.member` interop dispatch on `deftype`.
  `(.get x)` resolves when a user protocol declares a method named `get`, which
  is the mechanism a `proxy` over `ThreadLocal` would ride.
- `mf.clj` — `MultiFn` resolution. `(class mm)` prints `MultiFn` but the symbol
  does not resolve; `clojure.test/report` IS a MultiFn, so blocker 4 is a
  missing name, not a missing capability.
- `hostsurface.clj` — the host surface hive-test's `.cljc` files reach for
  (`clojure.edn`, `clojure.test`, `System/getenv`, `java.io.File`, `io/file`,
  `io/resource`, `PersistentQueue/EMPTY`, `slurp`/`spit`). All green.
- `overlay/` — a proxy-free `clojure/test/check/random.clj` placed FIRST on the
  classpath. Not a fix and not shippable: it exists so the blockers BEHIND
  `proxy` could be measured without waiting for `proxy`. It replaces the
  `(proxy [ThreadLocal] …)` cell with an atom, which is only sound because cljw
  is single-threaded.

        $B -cp .dev/probes/testcheck/overlay:<test.check>/src/main/clojure \
           -e "(require '[clojure.test.check])"

## pending-verified-project/

The finished `deps.edn` + `verify.clj` for
`test/conformance/verified_projects/test.check/`, held HERE until it is green.

Per that directory's README, the PRESENCE of a `verified_projects/<lib>/` dir is
the committed claim "this library loads and works on cljw". Blockers 2-4 are
open, so promoting it now would publish a claim one rung above what has been
measured. Move it into place in the same commit that closes blocker 2.

`verify.clj` already PASSES on JVM Clojure 1.12.1:

    OK test.check — seeded determinism, passing + failing property,
       shrink-to-minimal, rose-tree zip, seedless RNG

so it is a differential oracle rather than a cljw-shaped test — it cannot pass
by encoding a cljw bug as expected behaviour.
