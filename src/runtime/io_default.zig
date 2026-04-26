// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Process-wide default `std.Io` accessor.
//!
//! Zig 0.16 removed `std.Thread.Mutex` and friends; the replacement
//! `std.Io.Mutex` requires an `io` argument for lock/unlock. CW carries
//! many module-level mutexes (interned keywords, hooks, namespaces, etc.)
//! that don't have access to an `init.io` value at the call site.
//!
//! This module exposes a single shared `std.Io` that defaults to a
//! single-threaded io suitable for tests and pre-init code paths.
//! Production entry points (main, cache_gen) call `set(init.io)` early
//! to upgrade the shared io to the real cancelable one used by
//! `thread_pool.zig`. After that, every mutex picks up the production io.

const std = @import("std");

var single_threaded: std.Io.Threaded = .init_single_threaded;
var current_io: std.Io = undefined;
var initialized: bool = false;

/// Return the process-wide default io. Lazily initializes to a single-
/// threaded io on first call so tests and ad-hoc callers don't have to
/// remember to call `set()`.
pub fn get() std.Io {
    if (!initialized) {
        current_io = single_threaded.io();
        initialized = true;
    }
    return current_io;
}

/// Override the process-wide default io. Production entry points
/// (main/cache_gen) call this with `init.io` so the thread_pool path
/// gets the real cancelable mutex semantics.
pub fn set(io: std.Io) void {
    current_io = io;
    initialized = true;
}
