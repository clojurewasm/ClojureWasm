(module
  (import "mid" "quadruple" (func $quadruple (param i32) (result i32)))
  (func (export "octuple") (param i32) (result i32)
    local.get 0
    call $quadruple
    i32.const 2
    i32.mul))
