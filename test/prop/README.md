# Layer 7 — property tests

The properties themselves live in **`src/testing/prop_*.zig`**, not here.

`zig build test` compiles one module rooted at `src/main.zig`, and Zig refuses an
`@import` that reaches outside its module's directory. A property test that
exercises `runtime/collection/map.zig` therefore has to sit inside that module —
a test root under `test/` could only reach what `main.zig` re-exports, which is
almost nothing.

So the layer is split the way the compiler forces:

| Piece | Where | What it is |
|---|---|---|
| Engine | `src/testing/prop.zig` | generators, shrinking, `forAll`. Depends only on `std`, so `zig test src/testing/prop.zig` runs its own tests in seconds. |
| Properties | `src/testing/prop_collections.zig` | the laws, reached from `main.zig`'s test aggregator like every other test file. |
| Configuration | `build.zig` | `-Dprop-seed`, `-Dprop-iters`. Fixed defaults so the gate is deterministic. |

## Running

```sh
zig build test -Dwasm -Doptimize=ReleaseSafe          # gate defaults: fixed seed
zig build test -Dwasm -Dprop-seed=0xdecafbad -Dprop-iters=5000   # a sweep
zig test src/testing/prop.zig                          # the engine's own tests
```

A property that fails prints the shrunk counterexample and the exact command to
reproduce it. When a sweep finds a failure, **pin that seed into the default in
`build.zig`** as part of fixing it — otherwise the gate goes on not looking
where the bug was found.

## Writing one

A property needs an oracle that does not share an implementation with the thing
under test. The three that work here:

- **A law**: `pop` undoes `conj`; `dissoc` undoes `assoc`; order does not matter.
- **A model**: a plain Zig array doing the obviously-correct thing, fed the same
  operations as the persistent structure.
- **A second implementation**: the tree-walk backend against the VM (Layer 3
  already does this one).

Cross a representation boundary on purpose. `map` promotes past 16 entries,
`vector` spills its tail into a HAMT, `set` promotes at 8 — Discussion #12 was a
bug that only existed above one of those lines, and every fixture in the suite
sat below it.
