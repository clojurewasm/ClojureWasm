// SPDX-License-Identifier: EPL-2.0
//! Zone 0 I/O abstraction (ADR-0015, ROADMAP §9.6 / 4.13).
//!
//! Carries the **Tier 1** vtable declarations only — no `std.Io`
//! import. Consumer code (analyser, REPL, primitives) imports this
//! file; the concrete `std.Io` attachment lives in `io_default.zig`
//! (Tier 2, Zone 1) and is injected by `main()` so a future `std.Io`
//! reshape only touches one file.
//!
//! Each struct opaquely carries a `*const VTable` plus a context
//! pointer (`*anyopaque`) representing the underlying resource. The
//! semantic contract — blocking semantics, ownership, error set — is
//! documented on each struct so the Tier 2 implementor can honour it
//! across Zig versions.
//!
//! Phase 4 entry ships only the type shapes. Concrete `defaultReader()`
//! / `defaultWriter()` constructors land in `io_default.zig` as the
//! consumer paths (REPL, file load, primitive I/O) migrate off the
//! direct `std.Io.File` references they currently use. The migration
//! is opportunistic — touched files adopt the abstraction; old call
//! sites are not retroactively rewritten until a Zig stdlib reshape
//! forces the issue (the F140-F144 v0 precedent).

const std = @import("std");

/// Byte-level writer. Blocking; the caller owns flush + close timing.
/// Error set is `anyerror` so the Tier 2 implementation can surface
/// whatever the underlying transport raises (file I/O, network, in-
/// memory buffer, etc.) without an intermediate translation layer.
pub const Writer = struct {
    vtable: *const VTable,
    ctx: *anyopaque,

    pub const VTable = struct {
        write_all: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
        flush: *const fn (ctx: *anyopaque) anyerror!void,
        close: *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub fn writeAll(self: Writer, bytes: []const u8) anyerror!void {
        return self.vtable.write_all(self.ctx, bytes);
    }
    pub fn flush(self: Writer) anyerror!void {
        return self.vtable.flush(self.ctx);
    }
    pub fn close(self: Writer) anyerror!void {
        return self.vtable.close(self.ctx);
    }
};

/// Byte-level reader. Blocking. `read` returns the number of bytes
/// written into `dest`; `0` means clean EOF.
pub const Reader = struct {
    vtable: *const VTable,
    ctx: *anyopaque,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, dest: []u8) anyerror!usize,
        close: *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub fn read(self: Reader, dest: []u8) anyerror!usize {
        return self.vtable.read(self.ctx, dest);
    }
    pub fn close(self: Reader) anyerror!void {
        return self.vtable.close(self.ctx);
    }
};

/// Network endpoint abstraction — TCP-style connect / accept.
/// Phase 4 entry only declares the shape; concrete attachment to
/// `std.net` / `std.Io.Net` lands when the Phase-16 HTTP work
/// (per ADR-0006) re-enables the F140 / F141 surface.
pub const Net = struct {
    vtable: *const VTable,
    ctx: *anyopaque,

    pub const VTable = struct {
        connect: *const fn (ctx: *anyopaque, host: []const u8, port: u16) anyerror!Reader,
        listen: *const fn (ctx: *anyopaque, port: u16) anyerror!void,
        accept: *const fn (ctx: *anyopaque) anyerror!Reader,
        close: *const fn (ctx: *anyopaque) anyerror!void,
    };
};

/// Subprocess abstraction — spawn / wait / kill. Phase 4 entry only
/// declares the shape; the F144 `cljw build` self-bundle path
/// re-enables this in a later phase per ADR-0006.
pub const Process = struct {
    vtable: *const VTable,
    ctx: *anyopaque,

    pub const VTable = struct {
        spawn: *const fn (ctx: *anyopaque, argv: []const []const u8) anyerror!void,
        wait: *const fn (ctx: *anyopaque) anyerror!u8,
        kill: *const fn (ctx: *anyopaque) anyerror!void,
    };
};

// --- tests ---

const testing = std.testing;

test "Writer vtable shape: in-memory fixture round-trip" {
    var buf: [128]u8 = undefined;
    var ctx = TestWriterCtx{ .buf = &buf, .len = 0 };

    const Vt = struct {
        fn writeAll(c: *anyopaque, bytes: []const u8) anyerror!void {
            const self: *TestWriterCtx = @ptrCast(@alignCast(c));
            @memcpy(self.buf[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }
        fn flush(c: *anyopaque) anyerror!void {
            _ = c;
        }
        fn close(c: *anyopaque) anyerror!void {
            _ = c;
        }
    };
    const vt: Writer.VTable = .{ .write_all = Vt.writeAll, .flush = Vt.flush, .close = Vt.close };

    const w: Writer = .{ .vtable = &vt, .ctx = &ctx };
    try w.writeAll("hello");
    try w.flush();
    try testing.expectEqualStrings("hello", buf[0..ctx.len]);
}

test "Reader vtable shape: in-memory fixture EOF after one read" {
    var ctx = TestReaderCtx{ .src = "abc", .pos = 0 };
    const Vt = struct {
        fn read(c: *anyopaque, dest: []u8) anyerror!usize {
            const self: *TestReaderCtx = @ptrCast(@alignCast(c));
            const remaining = self.src.len - self.pos;
            if (remaining == 0) return 0;
            const n = @min(dest.len, remaining);
            @memcpy(dest[0..n], self.src[self.pos..][0..n]);
            self.pos += n;
            return n;
        }
        fn close(c: *anyopaque) anyerror!void {
            _ = c;
        }
    };
    const vt: Reader.VTable = .{ .read = Vt.read, .close = Vt.close };

    const r: Reader = .{ .vtable = &vt, .ctx = &ctx };
    var buf: [16]u8 = undefined;
    const n = try r.read(&buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("abc", buf[0..n]);
    try testing.expectEqual(@as(usize, 0), try r.read(&buf));
}

const TestWriterCtx = struct {
    buf: []u8,
    len: usize,
};

const TestReaderCtx = struct {
    src: []const u8,
    pos: usize,
};
