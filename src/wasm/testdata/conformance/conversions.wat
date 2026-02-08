;; Type conversion conformance tests
(module
  ;; i32 ↔ i64
  (func (export "i64_extend_i32_s") (param i32) (result i64)
    (i64.extend_i32_s (local.get 0)))

  (func (export "i64_extend_i32_u") (param i32) (result i64)
    (i64.extend_i32_u (local.get 0)))

  (func (export "i32_wrap_i64") (param i64) (result i32)
    (i32.wrap_i64 (local.get 0)))

  ;; float ↔ int
  (func (export "f64_convert_i32_s") (param i32) (result f64)
    (f64.convert_i32_s (local.get 0)))

  (func (export "f64_convert_i64_s") (param i64) (result f64)
    (f64.convert_i64_s (local.get 0)))

  (func (export "i32_trunc_f64_s") (param f64) (result i32)
    (i32.trunc_f64_s (local.get 0)))

  ;; f32 ↔ f64
  (func (export "f64_promote_f32") (param f32) (result f64)
    (f64.promote_f32 (local.get 0)))

  (func (export "f32_demote_f64") (param f64) (result f32)
    (f32.demote_f64 (local.get 0)))

  ;; reinterpret
  (func (export "i32_reinterpret_f32") (param f32) (result i32)
    (i32.reinterpret_f32 (local.get 0)))

  (func (export "f32_reinterpret_i32") (param i32) (result f32)
    (f32.reinterpret_i32 (local.get 0)))
)
