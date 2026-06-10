;; sieve — Sieve of Eratosthenes, (sieve n) -> i32 = count of primes below n.
;; sieve(65536) = 6542. Memory-heavy: marks composites in a byte-per-number
;; array. memory.fill re-zeroes the working range on entry so repeated calls on
;; the same instance are independent. 2 pages (128 KiB) >= the 65536-byte array.
;; Build: wasm-tools parse sieve.wat -o sieve.wasm
(module
  (memory (export "mem") 2)
  (func (export "sieve") (param $n i32) (result i32)
    (local $i i32) (local $j i32) (local $count i32)
    (memory.fill (i32.const 0) (i32.const 0) (local.get $n))
    (local.set $i (i32.const 2))
    (block $bi
      (loop $ci
        (br_if $bi (i32.ge_s (local.get $i) (local.get $n)))
        (if (i32.eqz (i32.load8_u (local.get $i)))
          (then
            (local.set $count (i32.add (local.get $count) (i32.const 1)))
            (local.set $j (i32.mul (local.get $i) (i32.const 2)))
            (block $bj
              (loop $cj
                (br_if $bj (i32.ge_s (local.get $j) (local.get $n)))
                (i32.store8 (local.get $j) (i32.const 1))
                (local.set $j (i32.add (local.get $j) (local.get $i)))
                (br $cj)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $ci)))
    (local.get $count)))
