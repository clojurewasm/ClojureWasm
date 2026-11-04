// SPDX-License-Identifier: EPL-2.0
//! glibc malloc tuning for the process heap: the startup mmap-threshold pin
//! and the idle `malloc_trim` (CLJW-BBMCP-MEMORY).
//!
//! cljw's runtime gpa is `c_allocator`, so on glibc every non-GC buffer goes
//! through glibc malloc. glibc raises its mmap threshold dynamically (up to
//! 32 MiB) the first time a mmapped chunk is freed, after which the 64-256 KiB
//! response buffers a server like bb-mcp churns land in the worker threads'
//! arenas, fragment, and are only partly trimmable: RSS creeps per request.
//! `pinMmapThreshold` sets `M_MMAP_THRESHOLD` explicitly, which also disables
//! the dynamic adjustment, so large buffers stay on mmap/munmap.
//!
//! Both functions compile to nothing off glibc (macOS, musl, wasm): those
//! allocators unmap large frees themselves. A user-set `GLIBC_TUNABLES` wins:
//! the pin is skipped so the operator's tuning is not overridden.

const builtin = @import("builtin");

/// True when this build links glibc, the only libc these calls exist in.
const is_glibc = builtin.link_libc and builtin.target.abi.isGnu();

/// glibc's `M_MMAP_THRESHOLD` mallopt parameter (malloc.h).
const m_mmap_threshold: c_int = -3;

/// Allocations at or above this size are served by mmap. 128 KiB is glibc's
/// own default starting threshold; pinning it is what stops the creep.
pub const mmap_threshold_bytes: c_int = 128 * 1024;

extern "c" fn mallopt(param: c_int, value: c_int) c_int;
extern "c" fn malloc_trim(pad: usize) c_int;

/// Pin glibc's mmap threshold at process start, before any worker thread
/// exists. `user_tunables` is true when `GLIBC_TUNABLES` is set in the
/// environment; the pin then defers to it.
pub fn pinMmapThreshold(user_tunables: bool) void {
    if (comptime !is_glibc) return;
    if (user_tunables) return;
    _ = mallopt(m_mmap_threshold, mmap_threshold_bytes);
}

/// Return glibc's free arena memory to the OS (called when the mutator goes
/// idle). A no-op off glibc.
pub fn trimProcessHeap() void {
    if (comptime is_glibc) _ = malloc_trim(0);
}

test "glibc policy calls are safe on every target" {
    pinMmapThreshold(true);
    trimProcessHeap();
}
