;; D-568 fixture: a component with ONE core module and no imports, so zwasm's
;; `open` takes the `.single` fast path, yet its export returns `own<counter>`.
;; `.single` carries no resource table, so dropping that handle is the
;; `NoResourceTable` condition, distinct from a guest trap.
;; Rebuild: wasm-tools parse single_resource.wat -o single_resource.wasm
(component
  (type $counter (resource (rep i32)))
  (export $c "counter" (type $counter))
  (core module $m
    (memory (export "memory") 1)
    (func (export "make") (result i32) i32.const 1))
  (core instance $i (instantiate $m))
  (func $make (result (own $c)) (canon lift (core func $i "make")))
  (export "make-counter" (func $make)))
