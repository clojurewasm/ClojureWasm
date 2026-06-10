;; fib — recursive Fibonacci, (fib n) -> i32. fib(20) = 6765.
;; Recursion-heavy kernel: measures wasm-side call/branch cost over the FFI.
;; Build: wasm-tools parse fib.wat -o fib.wasm
(module
  (func $fib (export "fib") (param $n i32) (result i32)
    (if (result i32) (i32.le_s (local.get $n) (i32.const 1))
      (then (local.get $n))
      (else
        (i32.add
          (call $fib (i32.sub (local.get $n) (i32.const 1)))
          (call $fib (i32.sub (local.get $n) (i32.const 2))))))))
