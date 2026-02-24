;; Block/loop/if control flow conformance tests
(module
  ;; Block returning a value
  (func (export "block_result") (result i32)
    (block (result i32)
      (i32.const 42)))

  ;; Nested blocks with br
  (func (export "nested_br") (param i32) (result i32)
    (block (result i32)
      (block (result i32)
        (i32.const 99)              ;; value to carry if branch taken
        (local.get 0)
        (br_if 1)                   ;; if param != 0, break to outer with 99
        (drop)                      ;; discard 99
        (i32.const 10))             ;; inner block result: 10
      (drop)                        ;; discard inner result
      (i32.const 20)))              ;; outer block result: 20

  ;; Loop with accumulator
  (func (export "loop_sum") (param i32) (result i32)
    (local i32) ;; accumulator
    (block
      (loop
        (local.set 1 (i32.add (local.get 1) (local.get 0)))
        (local.set 0 (i32.sub (local.get 0) (i32.const 1)))
        (br_if 0 (i32.gt_s (local.get 0) (i32.const 0)))))
    (local.get 1))

  ;; If/else
  (func (export "if_else") (param i32) (result i32)
    (if (result i32) (local.get 0)
      (then (i32.const 1))
      (else (i32.const 0))))
)
