;; arith_loop — sum 0..n-1 accumulated in i64, (arith_loop n) -> i64.
;; arith_loop(1000000) = 499999500000 (exceeds i32, so the export returns i64 —
;; this doubles as a check that the cljw FFI marshals a 64-bit wasm result).
;; Build: wasm-tools parse arith.wat -o arith.wasm
(module
  (func (export "arith_loop") (param $n i32) (result i64)
    (local $i i32) (local $sum i64)
    (local.set $sum (i64.const 0))
    (block $break
      (loop $cont
        (br_if $break (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $sum (i64.add (local.get $sum) (i64.extend_i32_s (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cont)))
    (local.get $sum)))
