;; add — minimal FFI kernel: (add a b) -> a+b (i32).
;; Used by the wasm_call benchmark to measure the cljw -> wasm -> return
;; boundary cost of a trivial export. No imports, so wasm/load instantiates it
;; directly (the cljw FFI surface accepts import-free modules only).
;; Build: wasm-tools parse add.wat -o add.wasm
(module
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add))
