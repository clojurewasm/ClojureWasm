(module
  (import "math" "add" (func $add (param i32 i32) (result i32)))
  (import "math" "mul" (func $mul (param i32 i32) (result i32)))
  (func (export "add_and_mul") (param i32 i32 i32) (result i32)
    ;; (a + b) * c
    local.get 0
    local.get 1
    call $add
    local.get 2
    call $mul))
