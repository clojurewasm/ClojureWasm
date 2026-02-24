(module
  (import "base" "double" (func $double (param i32) (result i32)))
  (func (export "quadruple") (param i32) (result i32)
    local.get 0
    call $double
    call $double))
