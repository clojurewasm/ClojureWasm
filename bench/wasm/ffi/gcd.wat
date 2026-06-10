;; gcd — Euclidean greatest common divisor, (gcd a b) -> i32. gcd(1071,462) = 21.
;; Recursion with a modulo each frame: a different arithmetic mix (i32.rem_u)
;; from the additive fib / comparison-only tak kernels.
;; Build: wasm-tools parse gcd.wat -o gcd.wasm
(module
  (func $gcd (export "gcd") (param $a i32) (param $b i32) (result i32)
    (if (result i32) (i32.eqz (local.get $b))
      (then (local.get $a))
      (else (call $gcd (local.get $b) (i32.rem_u (local.get $a) (local.get $b)))))))
