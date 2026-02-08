;; SIMD basic conformance tests — v128 memory, const, splat, extract, bitwise
(module
  (memory (export "memory") 1)

  ;; v128.const → i32x4.extract_lane 0
  (func (export "const_extract") (result i32)
    (i32x4.extract_lane 0
      (v128.const i32x4 42 0 0 0)))

  ;; v128.const → i32x4.extract_lane 2
  (func (export "const_extract_lane2") (result i32)
    (i32x4.extract_lane 2
      (v128.const i32x4 10 20 30 40)))

  ;; i32x4.splat → i32x4.extract_lane
  (func (export "splat_i32") (param i32) (result i32)
    (i32x4.extract_lane 0
      (i32x4.splat (local.get 0))))

  ;; i8x16.splat → i8x16.extract_lane_u
  (func (export "splat_i8") (param i32) (result i32)
    (i8x16.extract_lane_u 5
      (i8x16.splat (local.get 0))))

  ;; v128.store + v128.load roundtrip
  (func (export "store_load") (result i32)
    ;; store v128.const at offset 0
    (v128.store (i32.const 0)
      (v128.const i32x4 100 200 300 400))
    ;; load and extract lane 1
    (i32x4.extract_lane 1
      (v128.load (i32.const 0))))

  ;; v128.not
  (func (export "v128_not") (result i32)
    ;; not of 0 should be all 1s; extract byte lane 0 = 0xFF = 255 unsigned
    (i8x16.extract_lane_u 0
      (v128.not (v128.const i32x4 0 0 0 0))))

  ;; v128.and
  (func (export "v128_and") (result i32)
    (i32x4.extract_lane 0
      (v128.and
        (v128.const i32x4 0xFF00FF 0 0 0)
        (v128.const i32x4 0x00FFFF 0 0 0))))

  ;; v128.or
  (func (export "v128_or") (result i32)
    (i32x4.extract_lane 0
      (v128.or
        (v128.const i32x4 0xF0 0 0 0)
        (v128.const i32x4 0x0F 0 0 0))))

  ;; v128.xor
  (func (export "v128_xor") (result i32)
    (i32x4.extract_lane 0
      (v128.xor
        (v128.const i32x4 0xFF 0 0 0)
        (v128.const i32x4 0x0F 0 0 0))))

  ;; v128.any_true (non-zero)
  (func (export "any_true_yes") (result i32)
    (v128.any_true (v128.const i32x4 0 0 1 0)))

  ;; v128.any_true (zero)
  (func (export "any_true_no") (result i32)
    (v128.any_true (v128.const i32x4 0 0 0 0)))

  ;; i8x16.shuffle — swap first two bytes
  (func (export "shuffle_swap") (result i32)
    (i8x16.extract_lane_u 0
      (i8x16.shuffle 1 0 2 3 4 5 6 7 8 9 10 11 12 13 14 15
        (v128.const i32x4 0x04030201 0 0 0)
        (v128.const i32x4 0 0 0 0))))

  ;; i32x4.replace_lane
  (func (export "replace_lane") (result i32)
    (i32x4.extract_lane 2
      (i32x4.replace_lane 2
        (v128.const i32x4 0 0 0 0)
        (i32.const 999))))

  ;; v128.load32_zero — load 4 bytes, rest zero
  (func (export "load32_zero") (result i32)
    ;; Write 42 at offset 0
    (i32.store (i32.const 0) (i32.const 42))
    ;; load32_zero: only first i32 = 42, rest = 0
    (i32x4.extract_lane 1
      (v128.load32_zero (i32.const 0))))

  ;; v128.load8_splat
  (func (export "load8_splat") (result i32)
    (i32.store8 (i32.const 0) (i32.const 7))
    (i8x16.extract_lane_u 15
      (v128.load8_splat (i32.const 0))))
)
