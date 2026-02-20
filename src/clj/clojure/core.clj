;; clojure.core bootstrap — EMPTY
;;
;; All macros and functions have been migrated to Zig:
;; - Functions → bootstrap.zig (hot_core_defs, core_hof_defs, core_seq_defs)
;; - Constants → bootstrap.zig (core_seq_defs)
;; - Macros → macro_transforms.zig
;;
;; This file is kept as a placeholder until Phase C (Bootstrap Pipeline Elimination)
;; removes the @embedFile + evalString mechanism entirely.
