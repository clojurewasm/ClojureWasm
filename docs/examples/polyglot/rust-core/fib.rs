//! A Rust compute kernel for cljw's core-module FFI (wasm/load + wasm/call).
//! `no_std`, no allocator, no imports: the module is a few hundred bytes and
//! instantiates with an empty import object.
//!
//! Build (single file, no Cargo):
//!   rustc --target wasm32-unknown-unknown --crate-type cdylib \
//!     -C opt-level=s -C panic=abort fib.rs -o fib.wasm
#![no_std]

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}

/// n-th Fibonacci number, iterative, wrapping at u64.
#[no_mangle]
pub extern "C" fn fib(n: u32) -> u64 {
    let (mut a, mut b) = (0u64, 1u64);
    for _ in 0..n {
        let t = a.wrapping_add(b);
        a = b;
        b = t;
    }
    a
}

/// Population count over a 64-bit word.
#[no_mangle]
pub extern "C" fn popcount(x: u64) -> u32 {
    x.count_ones()
}
