// A C compute kernel for cljw's core-module FFI (wasm/load + wasm/call).
// Numbers cross the boundary as scalars; arrays live in the guest's own
// linear memory, which the guest exposes by address.
//
// Build (no libc, no entry point; Zig's bundled clang targets wasm32). The
// linker's default shadow stack is 1 MB, which alone makes the module ask for
// 17 memory pages; 64 KB is plenty for a kernel like this and keeps it under
// a small :max-memory-pages budget.
//   zig cc -target wasm32-freestanding -O2 -nostdlib \
//     -Wl,--no-entry -Wl,--export-memory -Wl,-z,stack-size=65536 \
//     kernel.c -o kernel.wasm

#define EXPORT(name) __attribute__((export_name(name), visibility("default")))

static double buf[256];

// Address of the guest-owned buffer the host writes into.
EXPORT("buf_addr") int buf_addr(void) { return (int)(long)buf; }

// Capacity of that buffer, in doubles.
EXPORT("buf_cap") int buf_cap(void) { return (int)(sizeof buf / sizeof buf[0]); }

// Sum of n doubles starting at byte offset off.
EXPORT("sum_f64") double sum_f64(int off, int n) {
    const double *p = (const double *)(long)off;
    double s = 0.0;
    for (int i = 0; i < n; i++) s += p[i];
    return s;
}

// Multiply n doubles at byte offset off by k, in place; returns n. (A void
// export taking an f64 has no JIT call shape today and would need
// {:engine :interp}; returning a value keeps the kernel on the default engine.)
EXPORT("scale_f64") int scale_f64(int off, int n, double k) {
    double *p = (double *)(long)off;
    for (int i = 0; i < n; i++) p[i] *= k;
    return n;
}
