;; Bulk memory operations (Wasm 2.0 post-MVP)
(module
  (memory (export "memory") 1)

  (func (export "memory_fill") (param i32 i32 i32)
    (memory.fill (local.get 0) (local.get 1) (local.get 2)))

  (func (export "memory_copy") (param i32 i32 i32)
    (memory.copy (local.get 0) (local.get 1) (local.get 2)))

  (func (export "load_i32") (param i32) (result i32)
    (i32.load (local.get 0)))

  (func (export "store_i32") (param i32 i32)
    (i32.store (local.get 0) (local.get 1)))

  (func (export "load_i8") (param i32) (result i32)
    (i32.load8_u (local.get 0)))
)
