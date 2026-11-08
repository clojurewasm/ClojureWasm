//! A Zig compute kernel for cljw's core-module FFI (wasm/load + wasm/call).
//! Every `export fn` with scalar parameters is callable from Clojure by name.
//!
//! Build:
//!   zig build-exe numeric.zig -target wasm32-freestanding -O ReleaseSmall \
//!     -fno-entry -rdynamic -femit-bin=numeric.wasm

export fn gcd(a0: u64, b0: u64) u64 {
    var a = a0;
    var b = b0;
    while (b != 0) {
        const t = a % b;
        a = b;
        b = t;
    }
    return a;
}

export fn is_prime(n: u64) bool {
    if (n < 2) return false;
    if (n % 2 == 0) return n == 2;
    var d: u64 = 3;
    while (d * d <= n) : (d += 2) {
        if (n % d == 0) return false;
    }
    return true;
}

export fn collatz_steps(n0: u64) u32 {
    var n = n0;
    var steps: u32 = 0;
    while (n != 1) : (steps += 1) {
        n = if (n % 2 == 0) n / 2 else 3 * n + 1;
    }
    return steps;
}
