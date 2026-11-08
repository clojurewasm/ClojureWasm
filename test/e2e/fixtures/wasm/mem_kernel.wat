;; Source for mem_kernel.wasm — the (ptr,len) linear-memory fixture (ADR-0192).
;; Build: wat2wasm mem_kernel.wat -o mem_kernel.wasm   (or any wabt/wasm toolchain)
;;
;; mem_kernel.wasm is committed prebuilt so the e2e needs no wasm toolchain;
;; this .wat is the human-readable source for reproducibility.
;;
;; The two exports are the shape `wasm/call` alone cannot reach: an array
;; arrives as a (pointer, length) pair into linear memory, so the HOST has to
;; fill the buffer before the call and read it after.
;;
;; `scale_f64` returns the new sum rather than being void on purpose. It makes
;; one call prove both directions — the guest read what the host wrote, and the
;; host reads what the guest wrote — and it stays clear of D-585 (zwasm's JIT
;; traps a zero-result export outside a narrow window: arity <= 1, or arity 2-3
;; with no floating-point parameter. A void `scale(ptr, n, k)` is squarely
;; inside the trapping region; giving it a result takes it out).
(module
  (memory (export "memory") 1)

  ;; sum of `n` f64 starting at byte `ptr`
  (func (export "sum_f64") (param $ptr i32) (param $n i32) (result f64)
    (local $i i32) (local $acc f64)
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $acc
          (f64.add (local.get $acc)
                   (f64.load (i32.add (local.get $ptr)
                                      (i32.mul (local.get $i) (i32.const 8))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $acc))

  ;; multiply `n` f64 at byte `ptr` by `k` IN PLACE, then return the new sum
  (func (export "scale_f64") (param $ptr i32) (param $n i32) (param $k f64) (result f64)
    (local $i i32) (local $a i32) (local $acc f64)
    (block $scaled
      (loop $lp
        (br_if $scaled (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $a (i32.add (local.get $ptr) (i32.mul (local.get $i) (i32.const 8))))
        (f64.store (local.get $a) (f64.mul (f64.load (local.get $a)) (local.get $k)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.set $i (i32.const 0))
    (local.set $acc (f64.const 0))
    (block $summed
      (loop $lp2
        (br_if $summed (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $acc
          (f64.add (local.get $acc)
                   (f64.load (i32.add (local.get $ptr)
                                      (i32.mul (local.get $i) (i32.const 8))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp2)))
    (local.get $acc)))
