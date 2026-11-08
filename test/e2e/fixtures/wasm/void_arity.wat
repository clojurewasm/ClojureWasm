;; The D-585 discriminators (ADR-0196 e2e fixture): empty bodies that touch no
;; memory, so any engine difference is the signature alone.
;;   nop_void  vs nop_ret  : identical params, only the result arity differs.
;;   gpr4_void vs gpr4_ret : the same, with NO floating-point param anywhere.
;; Regenerate: wasm-tools parse void_arity.wat -o void_arity.wasm
(module
  (func (export "nop_void") (param i32 f64))
  (func (export "nop_ret")  (param i32 f64) (result f64) local.get 1)
  (func (export "gpr4_void") (param i32 i32 i32 i32))
  (func (export "gpr4_ret")  (param i32 i32 i32 i32) (result i32) i32.const 0))
