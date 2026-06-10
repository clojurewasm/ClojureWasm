;; fib_loop — iterative Fibonacci, (fib_loop n) -> i32. fib_loop(20) = 6765.
;; Loop-heavy counterpart to fib.wat: same result, no recursion, so the pair
;; isolates wasm recursion cost from raw loop cost over the FFI.
;; Build: wasm-tools parse fib_loop.wat -o fib_loop.wasm
(module
  (func (export "fib_loop") (param $n i32) (result i32)
    (local $a i32) (local $b i32) (local $t i32) (local $i i32)
    (local.set $a (i32.const 0))
    (local.set $b (i32.const 1))
    (block $break
      (loop $cont
        (br_if $break (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $t (i32.add (local.get $a) (local.get $b)))
        (local.set $a (local.get $b))
        (local.set $b (local.get $t))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cont)))
    (local.get $a)))
