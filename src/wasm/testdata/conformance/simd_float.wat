;; SIMD float arithmetic conformance tests
(module
  (memory (export "memory") 1)

  ;; f32x4.add: (1.5, 2.5, 3.5, 4.5) + (0.5, 0.5, 0.5, 0.5) = (2.0, 3.0, 4.0, 5.0)
  (func (export "f32x4_add") (result f32)
    (f32x4.extract_lane 0
      (f32x4.add
        (v128.const f32x4 1.5 2.5 3.5 4.5)
        (v128.const f32x4 0.5 0.5 0.5 0.5))))

  ;; f64x2.mul: (2.0, 3.0) * (4.0, 5.0) = (8.0, 15.0)
  (func (export "f64x2_mul") (result f64)
    (f64x2.extract_lane 0
      (f64x2.mul
        (v128.const f64x2 2.0 3.0)
        (v128.const f64x2 4.0 5.0))))

  ;; f32x4.eq: (1.0, 2.0, 3.0, 4.0) == (1.0, 0.0, 3.0, 0.0) → lane 0 = all-ones
  (func (export "f32x4_eq") (result i32)
    (i32x4.extract_lane 0
      (f32x4.eq
        (v128.const f32x4 1.0 2.0 3.0 4.0)
        (v128.const f32x4 1.0 0.0 3.0 0.0))))

  ;; f32x4.abs: (|-1.5|, |-2.5|, |3.5|, |-4.5|) = (1.5, 2.5, 3.5, 4.5)
  (func (export "f32x4_abs") (result f32)
    (f32x4.extract_lane 0
      (f32x4.abs
        (v128.const f32x4 -1.5 -2.5 3.5 -4.5))))

  ;; f32x4.neg: -(1.0, -2.0, 3.0, -4.0) = (-1.0, 2.0, -3.0, 4.0)
  (func (export "f32x4_neg") (result f32)
    (f32x4.extract_lane 0
      (f32x4.neg
        (v128.const f32x4 1.0 -2.0 3.0 -4.0))))

  ;; f32x4.sqrt: sqrt(4.0, 9.0, 16.0, 25.0) = (2.0, 3.0, 4.0, 5.0)
  (func (export "f32x4_sqrt") (result f32)
    (f32x4.extract_lane 0
      (f32x4.sqrt
        (v128.const f32x4 4.0 9.0 16.0 25.0))))

  ;; f32x4.ceil: ceil(1.3, 2.7, -1.3, -2.7) = (2.0, 3.0, -1.0, -2.0)
  (func (export "f32x4_ceil") (result f32)
    (f32x4.extract_lane 0
      (f32x4.ceil
        (v128.const f32x4 1.3 2.7 -1.3 -2.7))))

  ;; f32x4.floor: floor(1.7) = 1.0
  (func (export "f32x4_floor") (result f32)
    (f32x4.extract_lane 0
      (f32x4.floor
        (v128.const f32x4 1.7 0 0 0))))

  ;; f32x4.nearest: nearest(2.5) = 2.0 (round to even)
  (func (export "f32x4_nearest") (result f32)
    (f32x4.extract_lane 0
      (f32x4.nearest
        (v128.const f32x4 2.5 0 0 0))))

  ;; f32x4.min: min(1.0, 2.0) = 1.0
  (func (export "f32x4_min") (result f32)
    (f32x4.extract_lane 0
      (f32x4.min
        (v128.const f32x4 1.0 5.0 3.0 7.0)
        (v128.const f32x4 2.0 4.0 6.0 8.0))))

  ;; f32x4.max: max(1.0, 2.0) = 2.0
  (func (export "f32x4_max") (result f32)
    (f32x4.extract_lane 0
      (f32x4.max
        (v128.const f32x4 1.0 5.0 3.0 7.0)
        (v128.const f32x4 2.0 4.0 6.0 8.0))))

  ;; f32x4.pmin: pmin(3.0, 1.0) = 1.0 (b < a ? b : a)
  (func (export "f32x4_pmin") (result f32)
    (f32x4.extract_lane 0
      (f32x4.pmin
        (v128.const f32x4 3.0 0 0 0)
        (v128.const f32x4 1.0 0 0 0))))

  ;; i32x4.trunc_sat_f32x4_s: trunc(2.9) = 2
  (func (export "trunc_sat_s") (result i32)
    (i32x4.extract_lane 0
      (i32x4.trunc_sat_f32x4_s
        (v128.const f32x4 2.9 -3.1 0.0 1000000.0))))

  ;; f32x4.convert_i32x4_s: convert(42) = 42.0
  (func (export "convert_s") (result f32)
    (f32x4.extract_lane 0
      (f32x4.convert_i32x4_s
        (v128.const i32x4 42 -1 0 100))))

  ;; f32x4.demote_f64x2_zero: demote(3.14, 2.72) → (3.14f, 2.72f, 0, 0)
  (func (export "demote") (result f32)
    (f32x4.extract_lane 2
      (f32x4.demote_f64x2_zero
        (v128.const f64x2 3.14 2.72))))

  ;; f64x2.promote_low_f32x4: promote(1.5, 2.5, ...) → (1.5, 2.5)
  (func (export "promote") (result f64)
    (f64x2.extract_lane 0
      (f64x2.promote_low_f32x4
        (v128.const f32x4 1.5 2.5 3.5 4.5))))

  ;; f64x2.convert_low_i32x4_s: convert(-7, 42, ...) → (-7.0, 42.0)
  (func (export "f64_convert_s") (result f64)
    (f64x2.extract_lane 0
      (f64x2.convert_low_i32x4_s
        (v128.const i32x4 -7 42 0 0))))

  ;; i32x4.trunc_sat_f64x2_s_zero: trunc(9.9, -2.1) → (9, -2, 0, 0), lane 2 = 0
  (func (export "trunc_f64_zero") (result i32)
    (i32x4.extract_lane 2
      (i32x4.trunc_sat_f64x2_s_zero
        (v128.const f64x2 9.9 -2.1))))
)
