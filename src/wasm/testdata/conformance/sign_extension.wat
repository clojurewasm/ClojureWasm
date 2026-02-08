;; Sign extension operators (Wasm 2.0 post-MVP)
(module
  (func (export "i32_extend8_s") (param i32) (result i32)
    (i32.extend8_s (local.get 0)))

  (func (export "i32_extend16_s") (param i32) (result i32)
    (i32.extend16_s (local.get 0)))

  (func (export "i64_extend8_s") (param i64) (result i64)
    (i64.extend8_s (local.get 0)))

  (func (export "i64_extend16_s") (param i64) (result i64)
    (i64.extend16_s (local.get 0)))

  (func (export "i64_extend32_s") (param i64) (result i64)
    (i64.extend32_s (local.get 0)))
)
