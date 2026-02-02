# ClojureWasm Development Memo

## Current State

- Phase: 6 (Core Library Expansion)
- Roadmap: .dev/plan/roadmap.md
- Current task: T6.8 — Sequence transforms (partition, group-by, etc.)
- Task file: (none)
- Note: T4.7 (AOT bytecode startup) deferred — needs macro serialization
- Blockers: none

## Completed Phases

| Phase    | Archive                                                     | Date       |
| -------- | ----------------------------------------------------------- | ---------- |
| Phase 0  | .dev/plan/archive/plan_0000_kickoff.md                      | 2026-02-01 |
| T1.10    | .dev/plan/archive/task_0009_analyzer.md                     | 2026-02-01 |
| D3b      | .dev/plan/archive/task_0010_error_cleanup.md                | 2026-02-01 |
| T1.11    | .dev/plan/archive/task_0011_loop_recur_try.md               | 2026-02-01 |
| T2.1     | .dev/plan/archive/task_0012_env.md                          | 2026-02-01 |
| T2.2     | .dev/plan/archive/task_0013_namespace.md                    | 2026-02-01 |
| T2.3     | .dev/plan/archive/task_0014_var_kind_builtindef.md          | 2026-02-01 |
| T2.4     | .dev/plan/archive/task_0015_gc_strategy.md                  | 2026-02-01 |
| T2.5     | .dev/plan/archive/task_0016_opcodes.md                      | 2026-02-01 |
| T2.6     | .dev/plan/archive/task_0017_compiler.md                     | 2026-02-01 |
| T2.7     | .dev/plan/archive/task_0018_vm.md                           | 2026-02-01 |
| T2.8     | .dev/plan/archive/task_0019_closures.md                     | 2026-02-01 |
| T2.9     | .dev/plan/archive/task_0020_tree_walk.md                    | 2026-02-01 |
| T2.10    | .dev/plan/archive/task_0021_compare_mode.md                 | 2026-02-01 |
| T3.1     | .dev/plan/archive/task_0022_arithmetic_intrinsics.md        | 2026-02-01 |
| T3.2     | .dev/plan/archive/task_0023_var_def_opcodes.md              | 2026-02-01 |
| T3.3     | .dev/plan/archive/task_0024_recur_tail_call.md              | 2026-02-01 |
| T3.4     | .dev/plan/archive/task_0025_collection_exception_opcodes.md | 2026-02-01 |
| T3.5     | .dev/plan/archive/task_0026_builtin_registry.md             | 2026-02-01 |
| T3.6     | .dev/plan/archive/task_0027_collection_intrinsics.md        | 2026-02-02 |
| T3.7     | .dev/plan/archive/task_0028_type_predicates.md              | 2026-02-02 |
| T3.8     | .dev/plan/archive/task_0029_str_print_fns.md                | 2026-02-02 |
| T3.9     | .dev/plan/archive/task_0030_atom.md                         | 2026-02-02 |
| T3.10    | .dev/plan/archive/task_0031_core_bootstrap.md               | 2026-02-02 |
| T3.13    | .dev/plan/archive/task_0032_higher_order_fns.md             | 2026-02-02 |
| T3.14    | .dev/plan/archive/task_0033_core_macros.md                  | 2026-02-02 |
| T3.15    | .dev/plan/archive/task_0034_cli.md                          | 2026-02-02 |
| T3.16    | .dev/plan/archive/task_0035_sci_tests.md                    | 2026-02-02 |
| T3.17    | .dev/plan/archive/task_0036_benchmark.md                    | 2026-02-02 |
| T4.0     | .dev/plan/archive/task_0037_phase4_planning.md              | 2026-02-02 |
| T4.1     | .dev/plan/archive/task_0038_vm_variadic_arith.md            | 2026-02-02 |
| T4.2     | .dev/plan/archive/task_0039_vm_predicates.md                | 2026-02-02 |
| T4.3     | .dev/plan/archive/task_0040_vm_collection_ops.md            | 2026-02-02 |
| T4.4     | .dev/plan/archive/task_0041_vm_string_io_atom.md            | 2026-02-02 |
| T4.5     | .dev/plan/archive/task_0042_vm_compare_validation.md        | 2026-02-02 |
| T4.6     | .dev/plan/archive/task_0043_aot_pipeline.md                 | 2026-02-02 |
| T4.8     | .dev/plan/archive/task_0044_multi_arity_fn.md               | 2026-02-02 |
| T4.9     | .dev/plan/archive/task_0045_destructuring.md                | 2026-02-02 |
| T4.10    | .dev/plan/archive/task_0046_for_macro.md                    | 2026-02-02 |
| T4.11    | .dev/plan/archive/task_0047_protocols_defrecord.md          | 2026-02-02 |
| T4.12    | .dev/plan/archive/task_0048_interactive_repl.md             | 2026-02-02 |
| T4.13    | .dev/plan/archive/task_0049_wasm_target.md                  | 2026-02-02 |
| T4.14/15 | .dev/plan/archive/task_0050_dir_restructure.md              | 2026-02-02 |

**Phase 3a complete** — all 9 tasks (T3.1-T3.9) done.
**Phase 3c complete** — T3.15-T3.17 done. (T3.11/T3.12 AOT deferred to Phase 4c.)
