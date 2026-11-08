;; Full-range i64 marshalling fixture (CLJW-WASM-I64-FULL-RANGE). Identity
;; exports, so a round trip proves both directions: the arg was lowered to an
;; exact i64 and the result was lifted back to an exact Long. The i48 NaN-box
;; window (about +/-2^47) is where a cljw integer stops being an immediate, so
;; the interesting values all sit outside it.
;;   top_bit : a guest computing a u64 with the top bit set (what
;;             `@bitReverse(@as(u64, 1))` returns). wasm i64 is signless, so the
;;             host sees Long/MIN_VALUE, the JVM reading of the same 64 bits.
;;   swap64  : two i64 results, the vector-of-results path.
;; Regenerate: wat2wasm i64_range.wat -o i64_range.wasm
(module
  (memory (export "memory") 1)
  (func (export "id64") (param i64) (result i64) local.get 0)
  (func (export "id32") (param i32) (result i32) local.get 0)
  (func (export "idf64") (param f64) (result f64) local.get 0)
  (func (export "top_bit") (result i64) i64.const 0x8000000000000000)
  (func (export "swap64") (param i64 i64) (result i64 i64)
    local.get 1
    local.get 0))
