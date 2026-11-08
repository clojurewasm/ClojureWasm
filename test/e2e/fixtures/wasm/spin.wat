;; Core module of spin_component.wasm (world `spin` in spin.wit).
;; Rebuild recipe: README_spin.md. Scalars only; the exported memory is there
;; because the Canonical ABI context requires one even for flat signatures.
(module
  (memory (export "memory") 1)

  ;; spin: func() -> u32. An infinite loop with no calls and no memory access,
  ;; the cheapest possible shape to keep a CPU busy forever.
  (func (export "spin") (result i32)
    (loop $forever
      (br $forever))
    (i32.const 0))

  ;; ok: func() -> u32
  (func (export "ok") (result i32)
    (i32.const 42))

  ;; burn: func(n: u32) -> u32. Count n down to zero, return the original n.
  (func (export "burn") (param $n i32) (result i32)
    (local $i i32)
    (local.set $i (local.get $n))
    (block $done
      (loop $again
        (br_if $done (i32.eqz (local.get $i)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (br $again)))
    (local.get $n))

  ;; grow: func(pages: u32) -> s32. Previous size in pages, or -1 if refused.
  (func (export "grow") (param $pages i32) (result i32)
    (memory.grow (local.get $pages))))
