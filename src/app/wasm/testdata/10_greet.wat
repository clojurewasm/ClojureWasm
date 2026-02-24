(module
  ;; Linear memory (1 page = 64KB)
  (memory (export "memory") 1)

  ;; Bump allocator state: heap pointer starts at 1024
  (global $heap_ptr (mut i32) (i32.const 1024))

  ;; cabi_realloc — simplified bump allocator for Component Model ABI.
  ;; (old_ptr, old_size, align, new_size) -> new_ptr
  ;; Ignores old_ptr/old_size/align — pure bump allocation.
  (func $cabi_realloc (export "cabi_realloc")
    (param $old_ptr i32) (param $old_size i32) (param $align i32) (param $new_size i32)
    (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $heap_ptr))
    (global.set $heap_ptr (i32.add (local.get $ptr) (local.get $new_size)))
    (local.get $ptr)
  )

  ;; greet(name_ptr, name_len) -> (result_ptr, result_len)
  ;; Returns "Hello, <name>!" by concatenating in memory.
  ;; Multi-value return: (i32, i32) = (ptr, len)
  (func $greet (export "greet")
    (param $name_ptr i32) (param $name_len i32)
    (result i32 i32)
    (local $result_ptr i32)
    (local $result_len i32)
    (local $offset i32)

    ;; result_len = 7 ("Hello, ") + name_len + 1 ("!")
    (local.set $result_len
      (i32.add (i32.add (i32.const 7) (local.get $name_len)) (i32.const 1)))

    ;; Allocate result buffer
    (local.set $result_ptr
      (call $cabi_realloc (i32.const 0) (i32.const 0) (i32.const 1) (local.get $result_len)))

    ;; Copy "Hello, " (7 bytes)
    (local.set $offset (local.get $result_ptr))
    ;; H=72, e=101, l=108, l=108, o=111, ,=44, space=32
    (i32.store8 (local.get $offset) (i32.const 72))
    (i32.store8 (i32.add (local.get $offset) (i32.const 1)) (i32.const 101))
    (i32.store8 (i32.add (local.get $offset) (i32.const 2)) (i32.const 108))
    (i32.store8 (i32.add (local.get $offset) (i32.const 3)) (i32.const 108))
    (i32.store8 (i32.add (local.get $offset) (i32.const 4)) (i32.const 111))
    (i32.store8 (i32.add (local.get $offset) (i32.const 5)) (i32.const 44))
    (i32.store8 (i32.add (local.get $offset) (i32.const 6)) (i32.const 32))

    ;; Copy name from input
    (memory.copy
      (i32.add (local.get $result_ptr) (i32.const 7))
      (local.get $name_ptr)
      (local.get $name_len))

    ;; Append "!" at the end
    (i32.store8
      (i32.add (local.get $result_ptr)
               (i32.sub (local.get $result_len) (i32.const 1)))
      (i32.const 33))

    ;; Return (ptr, len)
    (local.get $result_ptr)
    (local.get $result_len)
  )
)
