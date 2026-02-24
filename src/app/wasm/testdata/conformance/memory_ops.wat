;; Memory operations conformance tests
(module
  (memory (export "memory") 1)

  (func (export "i32_store_load") (param i32 i32) (result i32)
    (i32.store (local.get 0) (local.get 1))
    (i32.load (local.get 0)))

  (func (export "i64_store_load") (param i32 i64) (result i64)
    (i64.store (local.get 0) (local.get 1))
    (i64.load (local.get 0)))

  (func (export "i32_store8_load8_u") (param i32 i32) (result i32)
    (i32.store8 (local.get 0) (local.get 1))
    (i32.load8_u (local.get 0)))

  (func (export "i32_store8_load8_s") (param i32 i32) (result i32)
    (i32.store8 (local.get 0) (local.get 1))
    (i32.load8_s (local.get 0)))

  (func (export "memory_size") (result i32)
    (memory.size))

  (func (export "memory_grow") (param i32) (result i32)
    (memory.grow (local.get 0)))
)
