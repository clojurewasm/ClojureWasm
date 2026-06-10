;; tak — Takeuchi function, (tak x y z) -> i32. tak(18,12,6) = 7.
;; Deep mutual-free recursion (three recursive calls per frame): stresses the
;; wasm call stack much harder than fib for the same input magnitude.
;; Build: wasm-tools parse tak.wat -o tak.wasm
(module
  (func $tak (export "tak") (param $x i32) (param $y i32) (param $z i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $y) (local.get $x))
      (then
        (call $tak
          (call $tak (i32.sub (local.get $x) (i32.const 1)) (local.get $y) (local.get $z))
          (call $tak (i32.sub (local.get $y) (i32.const 1)) (local.get $z) (local.get $x))
          (call $tak (i32.sub (local.get $z) (i32.const 1)) (local.get $x) (local.get $y))))
      (else (local.get $z)))))
