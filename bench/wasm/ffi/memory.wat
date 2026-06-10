;; memory — linear-memory store/load, exercising the wasm memory path over FFI.
;;   (store off val) -> val   writes val at byte offset off, returns val
;;   (load  off)     -> i32   reads the i32 at byte offset off
;; store returns its value (not void) so wasm/call always has a result to marshal.
;; One 64 KiB page is plenty for the benchmark's bounded offsets.
;; Build: wasm-tools parse memory.wat -o memory.wasm
(module
  (memory (export "mem") 1)
  (func (export "store") (param $off i32) (param $val i32) (result i32)
    (i32.store (local.get $off) (local.get $val))
    (local.get $val))
  (func (export "load") (param $off i32) (result i32)
    (i32.load (local.get $off))))
