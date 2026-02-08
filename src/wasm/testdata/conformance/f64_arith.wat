;; f64 arithmetic conformance tests
(module
  (func (export "add") (param f64 f64) (result f64)
    (f64.add (local.get 0) (local.get 1)))

  (func (export "mul") (param f64 f64) (result f64)
    (f64.mul (local.get 0) (local.get 1)))

  (func (export "sqrt") (param f64) (result f64)
    (f64.sqrt (local.get 0)))

  (func (export "min") (param f64 f64) (result f64)
    (f64.min (local.get 0) (local.get 1)))

  (func (export "max") (param f64 f64) (result f64)
    (f64.max (local.get 0) (local.get 1)))

  (func (export "floor") (param f64) (result f64)
    (f64.floor (local.get 0)))

  (func (export "ceil") (param f64) (result f64)
    (f64.ceil (local.get 0)))

  (func (export "abs") (param f64) (result f64)
    (f64.abs (local.get 0)))

  (func (export "neg") (param f64) (result f64)
    (f64.neg (local.get 0)))
)
