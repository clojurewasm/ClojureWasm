// SPDX-License-Identifier: EPL-2.0
//! Fast pseudo-random generator — namespace-neutral implementation
//! per F-009.
//!
//! Two surfaces consume this file:
//!   1. `runtime/java/util/Random.zig` — `java.util.Random`
//!      (seedable, deterministic given the seed).
//!   2. (future) `lang/primitive/random.zig` for `clojure.core/rand`
//!      / `rand-int` — clojure.core uses java.util.Random under the
//!      hood; cw v1 will route the same way once Phase 7 host
//!      dispatch fires `(.nextInt r bound)`. Until then `rand` /
//!      `rand-int` live in `lang/clj/clojure/core.clj`.
//!
//! Cryptographic randomness (CSPRNG) is NOT here — it goes through
//! `std.Io.randomSecure` directly today; a `runtime/crypto/secure_random.zig`
//! file lands at Phase 14+ if `java.security.SecureRandom` surfaces
//! grow.

const std = @import("std");

/// Re-export of Zig's reasonable default PRNG. Callers that need a
/// seedable / replayable random stream allocate one of these
/// directly (e.g. `var prng = Prng.init(seed);`).
pub const Prng = std.Random.DefaultPrng;

/// Process-wide non-secure PRNG for `(rand)` / `(rand-int n)`-style
/// random number consumers that don't need seed control. Seeded once
/// from a fresh kernel-random source at first access. Thread-local so
/// concurrent `(rand)` calls don't fight over a single mutex.
threadlocal var process_prng: ?Prng = null;

fn lazyPrng(io: std.Io) *Prng {
    if (process_prng == null) {
        var seed: u64 = 0;
        var seed_bytes: [8]u8 = undefined;
        std.Io.randomSecure(io, &seed_bytes) catch std.Io.random(io, &seed_bytes);
        seed = std.mem.readInt(u64, &seed_bytes, .little);
        process_prng = Prng.init(seed);
    }
    return &process_prng.?;
}

/// Returns `[0, bound)` non-negative i32. `bound` must be > 0.
pub fn nextIntBound(io: std.Io, bound: i32) i32 {
    std.debug.assert(bound > 0);
    return @intCast(lazyPrng(io).random().intRangeLessThan(u32, 0, @intCast(bound)));
}

/// Returns a uniform-random double in `[0.0, 1.0)`. Matches
/// `java.util.Random.nextDouble`.
pub fn nextDouble(io: std.Io) f64 {
    return lazyPrng(io).random().float(f64);
}

// --- tests ---

const testing = std.testing;

test "nextIntBound stays within [0, bound)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const v = nextIntBound(th.io(), 100);
        try testing.expect(v >= 0 and v < 100);
    }
}

test "nextDouble stays within [0.0, 1.0)" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const v = nextDouble(th.io());
        try testing.expect(v >= 0.0 and v < 1.0);
    }
}
