;; i64 arithmetic conformance tests
(module
  (func (export "add") (param i64 i64) (result i64)
    (i64.add (local.get 0) (local.get 1)))

  (func (export "sub") (param i64 i64) (result i64)
    (i64.sub (local.get 0) (local.get 1)))

  (func (export "mul") (param i64 i64) (result i64)
    (i64.mul (local.get 0) (local.get 1)))

  (func (export "div_s") (param i64 i64) (result i64)
    (i64.div_s (local.get 0) (local.get 1)))

  (func (export "clz") (param i64) (result i64)
    (i64.clz (local.get 0)))

  (func (export "popcnt") (param i64) (result i64)
    (i64.popcnt (local.get 0)))

  (func (export "eqz") (param i64) (result i32)
    (i64.eqz (local.get 0)))
)
