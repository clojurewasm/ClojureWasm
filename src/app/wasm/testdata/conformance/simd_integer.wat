;; SIMD integer arithmetic conformance tests
(module
  (memory (export "memory") 1)

  ;; i32x4.eq: (1,2,3,4) == (1,0,3,0) → (-1,0,-1,0)
  (func (export "i32x4_eq") (result i32)
    (i32x4.extract_lane 0
      (i32x4.eq
        (v128.const i32x4 1 2 3 4)
        (v128.const i32x4 1 0 3 0))))

  ;; i32x4.lt_s: (-1,0,1,2) < (0,0,0,0) → (-1,0,0,0), lane 0 = -1
  (func (export "i32x4_lt_s") (result i32)
    (i32x4.extract_lane 0
      (i32x4.lt_s
        (v128.const i32x4 -1 0 1 2)
        (v128.const i32x4 0 0 0 0))))

  ;; i8x16.add: (100,200,...) + (1,1,...) → (101,201,...)
  (func (export "i8x16_add") (result i32)
    (i8x16.extract_lane_u 0
      (i8x16.add
        (v128.const i32x4 0x64646464 0 0 0)
        (v128.const i32x4 0x01010101 0 0 0))))

  ;; i16x8.mul: (10,20,...) * (3,3,...) → (30,60,...), lane 0 = 30
  (func (export "i16x8_mul") (result i32)
    (i16x8.extract_lane_u 0
      (i16x8.mul
        (v128.const i16x8 10 20 30 40 50 60 70 80)
        (v128.const i16x8 3 3 3 3 3 3 3 3))))

  ;; i8x16.add_sat_s: (120,...) +| (120,...) → (127,...) = clamped
  (func (export "i8x16_add_sat_s") (result i32)
    (i8x16.extract_lane_s 0
      (i8x16.add_sat_s
        (v128.const i32x4 0x78787878 0 0 0)
        (v128.const i32x4 0x78787878 0 0 0))))

  ;; i32x4.shl: (1,2,3,4) << 2 → (4,8,12,16)
  (func (export "i32x4_shl") (result i32)
    (i32x4.extract_lane 0
      (i32x4.shl
        (v128.const i32x4 1 2 3 4)
        (i32.const 2))))

  ;; i32x4.shr_s: (-8,...) >> 1 → (-4,...) arithmetic
  (func (export "i32x4_shr_s") (result i32)
    (i32x4.extract_lane 0
      (i32x4.shr_s
        (v128.const i32x4 -8 0 0 0)
        (i32.const 1))))

  ;; i32x4.abs: (-5,...) → (5,...), lane 0 = 5
  (func (export "i32x4_abs") (result i32)
    (i32x4.extract_lane 0
      (i32x4.abs
        (v128.const i32x4 -5 -10 15 -20))))

  ;; i32x4.neg: (5,...) → (-5,...), lane 0 = -5
  (func (export "i32x4_neg") (result i32)
    (i32x4.extract_lane 0
      (i32x4.neg
        (v128.const i32x4 5 10 15 20))))

  ;; i8x16.min_s: min(10, 20) = 10
  (func (export "i8x16_min_s") (result i32)
    (i8x16.extract_lane_u 0
      (i8x16.min_s
        (v128.const i32x4 0x0A0A0A0A 0 0 0)
        (v128.const i32x4 0x14141414 0 0 0))))

  ;; i32x4.max_s: max(10, 20) = 20
  (func (export "i32x4_max_s") (result i32)
    (i32x4.extract_lane 0
      (i32x4.max_s
        (v128.const i32x4 10 0 0 0)
        (v128.const i32x4 20 0 0 0))))

  ;; i16x8.narrow_i32x4_s: narrow (32768,...) to i16 saturated → 32767
  (func (export "narrow_sat") (result i32)
    (i16x8.extract_lane_s 0
      (i16x8.narrow_i32x4_s
        (v128.const i32x4 32768 0 0 0)
        (v128.const i32x4 0 0 0 0))))

  ;; i32x4.extend_low_i16x8_s: sign-extend low half
  (func (export "extend_low_s") (result i32)
    (i32x4.extract_lane 0
      (i32x4.extend_low_i16x8_s
        (v128.const i16x8 -5 10 -20 30 40 50 60 70))))

  ;; i32x4.extmul_low_i16x8_s: extended multiply low
  (func (export "extmul_low_s") (result i32)
    (i32x4.extract_lane 0
      (i32x4.extmul_low_i16x8_s
        (v128.const i16x8 -10 20 -30 40 0 0 0 0)
        (v128.const i16x8 5 5 5 5 0 0 0 0))))

  ;; i32x4.dot_i16x8_s: dot product of adjacent pairs
  ;; lane 0 = 1*2 + 3*4 = 2+12 = 14
  (func (export "dot_product") (result i32)
    (i32x4.extract_lane 0
      (i32x4.dot_i16x8_s
        (v128.const i16x8 1 3 5 7 9 11 13 15)
        (v128.const i16x8 2 4 6 8 10 12 14 16))))

  ;; i8x16.all_true: all non-zero → 1
  (func (export "all_true_yes") (result i32)
    (i8x16.all_true
      (v128.const i32x4 0x01020304 0x05060708 0x090A0B0C 0x0D0E0F10)))

  ;; i8x16.all_true: has zero → 0
  (func (export "all_true_no") (result i32)
    (i8x16.all_true
      (v128.const i32x4 0x01020304 0x00060708 0x090A0B0C 0x0D0E0F10)))

  ;; i32x4.bitmask: sign bits of (-1, 0, -1, 0) → 0b0101 = 5
  (func (export "bitmask") (result i32)
    (i32x4.bitmask
      (v128.const i32x4 -1 0 -1 0)))

  ;; i8x16.popcnt: popcount(0xFF) = 8
  (func (export "popcnt") (result i32)
    (i8x16.extract_lane_u 0
      (i8x16.popcnt
        (v128.const i32x4 0x000000FF 0 0 0))))

  ;; i16x8.extadd_pairwise_i8x16_s: add pairs sign-extended
  ;; lane 0 = (-1) + 2 = 1
  (func (export "extadd_pairwise") (result i32)
    (i16x8.extract_lane_s 0
      (i16x8.extadd_pairwise_i8x16_s
        (v128.const i32x4 0x000002FF 0 0 0))))

  ;; i8x16.avgr_u: (10, ...) avgr (20, ...) → 15
  (func (export "avgr_u") (result i32)
    (i8x16.extract_lane_u 0
      (i8x16.avgr_u
        (v128.const i32x4 0x0A0A0A0A 0 0 0)
        (v128.const i32x4 0x14141414 0 0 0))))
)
