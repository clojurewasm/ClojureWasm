# T9.5.4: VM benchmark baseline

## Goal

Run all 11 benchmarks with --backend=vm, document current VM status.
Not expected to pass all — this establishes what works and what doesn't.

## Results

### Passing (3/11)

| Benchmark     | VM Time | Notes             |
| ------------- | ------- | ----------------- |
| fib_recursive | 59ms    | Pure recursion OK |
| tak           | 24ms    | Takeuchi function |
| atom_reset    | 20ms    | Atom state ops    |

### Failing (8/11)

| Benchmark         | Error             | Root Cause                         |
| ----------------- | ----------------- | ---------------------------------- |
| fib_loop          | Wrong result (25) | loop/recur issue in VM             |
| arith_loop        | Wrong (1000000)   | loop/recur or variadic arith       |
| map_filter_reduce | VM eval failed    | Needs core.clj HOFs via dispatcher |
| vector_ops        | VM eval failed    | Needs core.clj HOFs via dispatcher |
| map_ops           | VM eval failed    | Needs core.clj HOFs via dispatcher |
| list_build        | VM eval failed    | Needs core.clj HOFs via dispatcher |
| sieve             | VM eval failed    | Needs filter/range etc.            |
| nqueens           | Wrong result (8)  | Partial — needs full HOF support   |

### Comparison with TreeWalk baseline

| Benchmark     | TreeWalk (Debug) | VM (Debug) | Speedup |
| ------------- | ---------------- | ---------- | ------- |
| fib_recursive | 3195ms           | 59ms       | 54x     |
| tak           | 500ms            | 24ms       | 21x     |
| atom_reset    | 47ms             | 20ms       | 2.4x    |

## Plan

Record results in task file. No bench.yaml update (too many failures).
Document VM parity gaps for future work.

## Log

- Ran all 11 benchmarks with --backend=vm
- 3 pass, 8 fail (VM feature gaps, not crashes)
- fib_recursive shows 54x speedup over TreeWalk — VM is working well for pure computation
- HOF/collection benchmarks need core.clj functions callable from VM (F8 unified fn_val proto)
- loop/recur benchmarks suggest a bug in VM loop handling
