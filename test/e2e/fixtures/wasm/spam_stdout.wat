;; A WASI command that writes a 64-byte line to stdout forever. Measures how
;; much output cljw's `wasm/run` buffers before the default fuel budget stops it.
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  ;; iovec at 0: {ptr=8, len=64}; payload at 8.
  (data (i32.const 8) "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
  (func (export "_start")
    (i32.store (i32.const 0) (i32.const 8))
    (i32.store (i32.const 4) (i32.const 64))
    (loop $again
      (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 200)))
      (br $again))))
