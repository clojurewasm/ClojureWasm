;; ClojureWasm Stage-1 prologue.
;;
;; Loaded by `src/lang/bootstrap.zig::loadCore` after
;; `primitive.registerAll` and `macro_transforms.registerInto`. At this
;; point the analyser already understands `let` / `when` / `cond` / `->`
;; / `->>` / `and` / `or` / `if-let` / `when-let` (registered as Zig-
;; level Form transforms in `lang/macro_transforms.zig`).
;;
;; Stage 1 only uses today's special forms — `def`, `fn*`, `if` — plus
;; the bootstrap macros above. User-defined `defn` / `defmacro` arrive
;; in later Phase-3 tasks once the analyser routes user macros through
;; the evaluator.

(def not (fn* [x] (if x false true)))
