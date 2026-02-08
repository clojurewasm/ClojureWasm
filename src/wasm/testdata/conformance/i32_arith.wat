;; i32 arithmetic conformance tests
(module
  (func (export "add") (param i32 i32) (result i32)
    (i32.add (local.get 0) (local.get 1)))

  (func (export "sub") (param i32 i32) (result i32)
    (i32.sub (local.get 0) (local.get 1)))

  (func (export "mul") (param i32 i32) (result i32)
    (i32.mul (local.get 0) (local.get 1)))

  (func (export "div_s") (param i32 i32) (result i32)
    (i32.div_s (local.get 0) (local.get 1)))

  (func (export "div_u") (param i32 i32) (result i32)
    (i32.div_u (local.get 0) (local.get 1)))

  (func (export "rem_s") (param i32 i32) (result i32)
    (i32.rem_s (local.get 0) (local.get 1)))

  (func (export "clz") (param i32) (result i32)
    (i32.clz (local.get 0)))

  (func (export "ctz") (param i32) (result i32)
    (i32.ctz (local.get 0)))

  (func (export "popcnt") (param i32) (result i32)
    (i32.popcnt (local.get 0)))

  (func (export "rotl") (param i32 i32) (result i32)
    (i32.rotl (local.get 0) (local.get 1)))

  (func (export "rotr") (param i32 i32) (result i32)
    (i32.rotr (local.get 0) (local.get 1)))
)
