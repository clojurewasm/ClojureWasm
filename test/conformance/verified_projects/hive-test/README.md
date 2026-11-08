# Native runtime laws

From this directory, run the repository's built `cljw -M:verify` for the
library integration proof, or `cljw -M:laws` for runtime regressions.
Both commands use the source pins in `deps.edn`.

`laws` runs 2400 generated cases with recorded seeds, three reviewed JVM
goldens, and seven mutation witnesses. Properties cover split `apply` arguments,
concatenation order, subvector partition conservation, fractional repeat
counts, literal replacement, and list type/value preservation. Mutation witnesses change the production
`subvec`, `split-lines`, `replace` and `list` Vars, then restore them in `finally`.
Run this command serially: Var root mutations affect the process.

The EDN snapshots were derived from Clojure 1.12.4 after checking behavior.
Review changes against that oracle. To replay a property with another seed,
call its test.check function, for example
`(laws/concat-preserves-order 300 :seed 20260910)`.

## Goldens are anchored, and a missing one is a failure

`hive-test` can create a missing snapshot and pass, and on native cljw it used
to resolve the snapshot against the working directory, because
`clojure.java.io/resource` returns nil for every name by design (D-359). A warm
session rooted at the repository therefore wrote an unreviewed baseline at the
repo root and reported success.

`golden_anchor.clj` closes both halves through the seams hive-test already
publishes. `laws/-main` calls `anchor/install`, which resolves this directory
and asserts the reviewed corpus in one call, then binds a store that refuses to
create a golden unless `UPDATE_GOLDEN=true`. So:

- a missing reviewed golden FAILS and names the file, rather than being captured
- the same four `.edn` files are used whatever the working directory is
- `CLJW_GOLDEN_ROOT` overrides discovery if you need to point elsewhere

    cljw -M:anchor-test        the anchor's own suite, no disk touched
    clojure -M:anchor-test     the same 17 tests on the JVM

The anchor is split so its decisions are pure: `candidate-order` is a function
of four strings, with `Environment` and `Filesystem` ports above it, so the
whole rule is exercised against an in-memory tree.

These are targeted witnesses, not a source mutation score. Broader Zig source
mutation campaigns remain on demand through `scripts/mutation/run.sh`, with
`--build-args "-Dwasm -Doptimize=ReleaseSafe"` and a green baseline.
