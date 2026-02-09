// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// WASI Preview 1 implementation for custom Wasm runtime.
//
// Provides 19 WASI snapshot_preview1 functions for basic I/O, args, environ,
// clock, random, and filesystem operations. Host functions pop args from the
// Wasm operand stack, perform the operation, and push errno result.

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const Allocator = mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const WasmError = vm_mod.WasmError;
const WasmMemory = @import("memory.zig").Memory;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const opcode = @import("opcode.zig");
const ValType = opcode.ValType;

// ============================================================
// WASI errno codes (wasi_snapshot_preview1)
// ============================================================

pub const Errno = enum(u32) {
    SUCCESS = 0,
    TOOBIG = 1,
    ACCES = 2,
    ADDRINUSE = 3,
    ADDRNOTAVAIL = 4,
    AFNOSUPPORT = 5,
    AGAIN = 6,
    ALREADY = 7,
    BADF = 8,
    BADMSG = 9,
    BUSY = 10,
    CANCELED = 11,
    CHILD = 12,
    CONNABORTED = 13,
    CONNREFUSED = 14,
    CONNRESET = 15,
    DEADLK = 16,
    DESTADDRREQ = 17,
    DOM = 18,
    DQUOT = 19,
    EXIST = 20,
    FAULT = 21,
    FBIG = 22,
    HOSTUNREACH = 23,
    IDRM = 24,
    ILSEQ = 25,
    INPROGRESS = 26,
    INTR = 27,
    INVAL = 28,
    IO = 29,
    ISCONN = 30,
    ISDIR = 31,
    LOOP = 32,
    MFILE = 33,
    MLINK = 34,
    MSGSIZE = 35,
    MULTIHOP = 36,
    NAMETOOLONG = 37,
    NETDOWN = 38,
    NETRESET = 39,
    NETUNREACH = 40,
    NFILE = 41,
    NOBUFS = 42,
    NODEV = 43,
    NOENT = 44,
    NOEXEC = 45,
    NOLCK = 46,
    NOLINK = 47,
    NOMEM = 48,
    NOMSG = 49,
    NOPROTOOPT = 50,
    NOSPC = 51,
    NOSYS = 52,
    NOTCONN = 53,
    NOTDIR = 54,
    NOTEMPTY = 55,
    NOTRECOVERABLE = 56,
    NOTSOCK = 57,
    NOTSUP = 58,
    NOTTY = 59,
    NXIO = 60,
    OVERFLOW = 61,
    OWNERDEAD = 62,
    PERM = 63,
    PIPE = 64,
    PROTO = 65,
    PROTONOSUPPORT = 66,
    PROTOTYPE = 67,
    RANGE = 68,
    ROFS = 69,
    SPIPE = 70,
    SRCH = 71,
    STALE = 72,
    TIMEDOUT = 73,
    TXTBSY = 74,
    XDEV = 75,
    NOTCAPABLE = 76,
};

pub const Filetype = enum(u8) {
    UNKNOWN = 0,
    BLOCK_DEVICE = 1,
    CHARACTER_DEVICE = 2,
    DIRECTORY = 3,
    REGULAR_FILE = 4,
    SOCKET_DGRAM = 5,
    SOCKET_STREAM = 6,
    SYMBOLIC_LINK = 7,
};

pub const Whence = enum(u8) {
    SET = 0,
    CUR = 1,
    END = 2,
};

pub const ClockId = enum(u32) {
    REALTIME = 0,
    MONOTONIC = 1,
    PROCESS_CPUTIME = 2,
    THREAD_CPUTIME = 3,
};

// ============================================================
// Preopened directory
// ============================================================

pub const Preopen = struct {
    wasi_fd: i32,
    path: []const u8,
    host_fd: posix.fd_t,
};

// ============================================================
// WASI context — per-instance WASI state
// ============================================================

pub const WasiContext = struct {
    args: []const [:0]const u8,
    environ_keys: std.ArrayList([]const u8),
    environ_vals: std.ArrayList([]const u8),
    preopens: std.ArrayList(Preopen),
    alloc: Allocator,
    exit_code: ?u32 = null,

    pub fn init(alloc: Allocator) WasiContext {
        return .{
            .args = &.{},
            .environ_keys = .empty,
            .environ_vals = .empty,
            .preopens = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *WasiContext) void {
        self.environ_keys.deinit(self.alloc);
        self.environ_vals.deinit(self.alloc);
        for (self.preopens.items) |p| {
            if (p.host_fd > 2) posix.close(p.host_fd);
        }
        self.preopens.deinit(self.alloc);
    }

    pub fn setArgs(self: *WasiContext, args: []const [:0]const u8) void {
        self.args = args;
    }

    pub fn addEnv(self: *WasiContext, key: []const u8, val: []const u8) !void {
        try self.environ_keys.append(self.alloc, key);
        try self.environ_vals.append(self.alloc, val);
    }

    pub fn addPreopen(self: *WasiContext, wasi_fd: i32, path: []const u8, host_fd: posix.fd_t) !void {
        try self.preopens.append(self.alloc, .{ .wasi_fd = wasi_fd, .path = path, .host_fd = host_fd });
    }

    fn getHostFd(self: *WasiContext, wasi_fd: i32) ?posix.fd_t {
        // Standard FDs map directly
        if (wasi_fd >= 0 and wasi_fd <= 2) return @intCast(wasi_fd);
        for (self.preopens.items) |p| {
            if (p.wasi_fd == wasi_fd) return p.host_fd;
        }
        return null;
    }
};

// ============================================================
// Helper: get Vm from host function context
// ============================================================

inline fn getVm(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

inline fn getWasi(vm: *Vm) ?*WasiContext {
    const inst = vm.current_instance orelse return null;
    return inst.wasi;
}

fn pushErrno(vm: *Vm, errno: Errno) !void {
    try vm.pushOperand(@intFromEnum(errno));
}

// ============================================================
// WASI function implementations
// ============================================================

/// args_sizes_get(argc_ptr: i32, argv_buf_size_ptr: i32) -> errno
pub fn args_sizes_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const argv_buf_size_ptr = vm.popOperandU32();
    const argc_ptr = vm.popOperandU32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const memory = try vm.getMemory(0);
    const argc: u32 = @intCast(wasi.args.len);
    try memory.write(u32, argc_ptr, 0, argc);

    var buf_size: u32 = 0;
    for (wasi.args) |arg| {
        buf_size += @intCast(arg.len + 1);
    }
    try memory.write(u32, argv_buf_size_ptr, 0, buf_size);

    try pushErrno(vm, .SUCCESS);
}

/// args_get(argv_ptr: i32, argv_buf_ptr: i32) -> errno
pub fn args_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const argv_buf_ptr = vm.popOperandU32();
    const argv_ptr = vm.popOperandU32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    var buf_offset: u32 = 0;
    for (wasi.args, 0..) |arg, i| {
        // Write pointer at argv[i]
        try memory.write(u32, argv_ptr, @as(u32, @intCast(i)) * 4, argv_buf_ptr + buf_offset);
        // Copy arg string + null terminator
        const dest_start = argv_buf_ptr + buf_offset;
        const arg_len: u32 = @intCast(arg.len);
        if (dest_start + arg_len + 1 > data.len) return error.OutOfBoundsMemoryAccess;
        @memcpy(data[dest_start .. dest_start + arg_len], arg[0..arg_len]);
        data[dest_start + arg_len] = 0;
        buf_offset += arg_len + 1;
    }

    try pushErrno(vm, .SUCCESS);
}

/// environ_sizes_get(count_ptr: i32, buf_size_ptr: i32) -> errno
pub fn environ_sizes_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const buf_size_ptr = vm.popOperandU32();
    const count_ptr = vm.popOperandU32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const memory = try vm.getMemory(0);
    const count: u32 = @intCast(wasi.environ_keys.items.len);
    try memory.write(u32, count_ptr, 0, count);

    var buf_size: u32 = 0;
    for (wasi.environ_keys.items, wasi.environ_vals.items) |key, val| {
        buf_size += @intCast(key.len + 1 + val.len + 1); // "KEY=val\0"
    }
    try memory.write(u32, buf_size_ptr, 0, buf_size);

    try pushErrno(vm, .SUCCESS);
}

/// environ_get(environ_ptr: i32, environ_buf_ptr: i32) -> errno
pub fn environ_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const environ_buf_ptr = vm.popOperandU32();
    const environ_ptr = vm.popOperandU32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    var buf_offset: u32 = 0;
    for (wasi.environ_keys.items, wasi.environ_vals.items, 0..) |key, val, i| {
        try memory.write(u32, environ_ptr, @as(u32, @intCast(i)) * 4, environ_buf_ptr + buf_offset);

        const dest = environ_buf_ptr + buf_offset;
        const total_len: u32 = @intCast(key.len + 1 + val.len + 1);
        if (dest + total_len > data.len) return error.OutOfBoundsMemoryAccess;

        @memcpy(data[dest .. dest + key.len], key);
        data[dest + @as(u32, @intCast(key.len))] = '=';
        const val_start = dest + @as(u32, @intCast(key.len)) + 1;
        @memcpy(data[val_start .. val_start + val.len], val);
        data[val_start + @as(u32, @intCast(val.len))] = 0;
        buf_offset += total_len;
    }

    try pushErrno(vm, .SUCCESS);
}

/// clock_time_get(clock_id: i32, precision: i64, time_ptr: i32) -> errno
pub fn clock_time_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const time_ptr = vm.popOperandU32();
    _ = vm.popOperandI64(); // precision (ignored)
    const clock_id = vm.popOperandU32();

    const memory = try vm.getMemory(0);

    const ts: i128 = switch (@as(ClockId, @enumFromInt(clock_id))) {
        .REALTIME => blk: {
            const t = std.time.nanoTimestamp();
            break :blk t;
        },
        .MONOTONIC, .PROCESS_CPUTIME, .THREAD_CPUTIME => blk: {
            const t = std.time.nanoTimestamp();
            break :blk t;
        },
    };
    const nanos: u64 = @intCast(@as(u128, @bitCast(ts)) & 0xFFFFFFFFFFFFFFFF);
    try memory.write(u64, time_ptr, 0, nanos);

    try pushErrno(vm, .SUCCESS);
}

/// fd_close(fd: i32) -> errno
pub fn fd_close(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const fd = vm.popOperandI32();

    // Don't close stdin/stdout/stderr
    if (fd <= 2) {
        try pushErrno(vm, .BADF);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    if (wasi.getHostFd(fd)) |host_fd| {
        posix.close(host_fd);
        try pushErrno(vm, .SUCCESS);
    } else {
        try pushErrno(vm, .BADF);
    }
}

/// fd_fdstat_get(fd: i32, stat_ptr: i32) -> errno
pub fn fd_fdstat_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const stat_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    // fdstat struct: filetype(u8) + padding(u8) + flags(u16) + rights_base(u64) + rights_inheriting(u64) = 24 bytes
    if (stat_ptr + 24 > data.len) return error.OutOfBoundsMemoryAccess;

    // Zero-fill then set filetype
    @memset(data[stat_ptr .. stat_ptr + 24], 0);

    const filetype: u8 = switch (fd) {
        0, 1, 2 => @intFromEnum(Filetype.CHARACTER_DEVICE),
        else => @intFromEnum(Filetype.DIRECTORY), // preopened dirs
    };
    data[stat_ptr] = filetype;

    // Set full rights
    const all_rights: u64 = 0x1FFFFFFF;
    try memory.write(u64, stat_ptr, 8, all_rights); // rights_base
    try memory.write(u64, stat_ptr, 16, all_rights); // rights_inheriting

    try pushErrno(vm, .SUCCESS);
}

/// fd_filestat_get(fd: i32, filestat_ptr: i32) -> errno
pub fn fd_filestat_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const filestat_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    // filestat struct: dev(u64) + ino(u64) + filetype(u8) + pad(7) + nlink(u64) + size(u64) + atim(u64) + mtim(u64) + ctim(u64) = 64 bytes
    if (filestat_ptr + 64 > data.len) return error.OutOfBoundsMemoryAccess;
    @memset(data[filestat_ptr .. filestat_ptr + 64], 0);

    // Set filetype at offset 16
    const filetype: u8 = switch (fd) {
        0, 1, 2 => @intFromEnum(Filetype.CHARACTER_DEVICE),
        else => @intFromEnum(Filetype.DIRECTORY),
    };
    data[filestat_ptr + 16] = filetype;
    // nlink = 1
    try memory.write(u64, filestat_ptr, 24, 1);

    try pushErrno(vm, .SUCCESS);
}

/// fd_prestat_get(fd: i32, prestat_ptr: i32) -> errno
pub fn fd_prestat_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const prestat_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    for (wasi.preopens.items) |p| {
        if (p.wasi_fd == fd) {
            const memory = try vm.getMemory(0);
            // prestat: tag(u32) = 0 (dir) + name_len(u32)
            try memory.write(u32, prestat_ptr, 0, 0); // tag = dir
            try memory.write(u32, prestat_ptr, 4, @intCast(p.path.len));
            try pushErrno(vm, .SUCCESS);
            return;
        }
    }

    try pushErrno(vm, .BADF);
}

/// fd_prestat_dir_name(fd: i32, path_ptr: i32, path_len: i32) -> errno
pub fn fd_prestat_dir_name(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    for (wasi.preopens.items) |p| {
        if (p.wasi_fd == fd) {
            const memory = try vm.getMemory(0);
            const data = memory.memory();
            const copy_len = @min(path_len, @as(u32, @intCast(p.path.len)));
            if (path_ptr + copy_len > data.len) return error.OutOfBoundsMemoryAccess;
            @memcpy(data[path_ptr .. path_ptr + copy_len], p.path[0..copy_len]);
            try pushErrno(vm, .SUCCESS);
            return;
        }
    }

    try pushErrno(vm, .BADF);
}

/// fd_read(fd: i32, iovs_ptr: i32, iovs_len: i32, nread_ptr: i32) -> errno
pub fn fd_read(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const nread_ptr = vm.popOperandU32();
    const iovs_len = vm.popOperandU32();
    const iovs_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm);
    const host_fd: posix.fd_t = if (wasi) |w| w.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    } else if (fd >= 0 and fd <= 2) @intCast(fd) else {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    var total: u32 = 0;
    for (0..iovs_len) |i| {
        const offset: u32 = @intCast(i * 8);
        const iov_ptr = try memory.read(u32, iovs_ptr, offset);
        const iov_len = try memory.read(u32, iovs_ptr, offset + 4);
        if (iov_ptr + iov_len > data.len) return error.OutOfBoundsMemoryAccess;

        const buf = data[iov_ptr .. iov_ptr + iov_len];
        const n = posix.read(host_fd, buf) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        };
        total += @intCast(n);
        if (n < buf.len) break;
    }

    try memory.write(u32, nread_ptr, 0, total);
    try pushErrno(vm, .SUCCESS);
}

/// fd_seek(fd: i32, offset: i64, whence: i32, newoffset_ptr: i32) -> errno
pub fn fd_seek(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const newoffset_ptr = vm.popOperandU32();
    const whence_val = vm.popOperandU32();
    const offset = vm.popOperandI64();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm);
    const host_fd: posix.fd_t = if (wasi) |w| w.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    } else if (fd >= 0 and fd <= 2) {
        try pushErrno(vm, .SPIPE);
        return;
    } else {
        try pushErrno(vm, .BADF);
        return;
    };

    switch (@as(Whence, @enumFromInt(whence_val))) {
        .SET => posix.lseek_SET(host_fd, @bitCast(offset)) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        },
        .CUR => posix.lseek_CUR(host_fd, offset) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        },
        .END => posix.lseek_END(host_fd, offset) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        },
    }

    const new_pos = posix.lseek_CUR_get(host_fd) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };

    const memory = try vm.getMemory(0);
    try memory.write(u64, newoffset_ptr, 0, new_pos);
    try pushErrno(vm, .SUCCESS);
}

/// fd_write(fd: i32, iovs_ptr: i32, iovs_len: i32, nwritten_ptr: i32) -> errno
pub fn fd_write(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const nwritten_ptr = vm.popOperandU32();
    const iovs_len = vm.popOperandU32();
    const iovs_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm);
    const host_fd: posix.fd_t = if (wasi) |w| w.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    } else if (fd >= 0 and fd <= 2) @intCast(fd) else {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    var total: u32 = 0;
    for (0..iovs_len) |i| {
        const offset: u32 = @intCast(i * 8);
        const iov_ptr = try memory.read(u32, iovs_ptr, offset);
        const iov_len = try memory.read(u32, iovs_ptr, offset + 4);
        if (iov_ptr + iov_len > data.len) return error.OutOfBoundsMemoryAccess;

        const buf = data[iov_ptr .. iov_ptr + iov_len];
        const n = posix.write(host_fd, buf) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        };
        total += @intCast(n);
        if (n < buf.len) break;
    }

    try memory.write(u32, nwritten_ptr, 0, total);
    try pushErrno(vm, .SUCCESS);
}

/// fd_tell(fd: i32, offset_ptr: i32) -> errno
pub fn fd_tell(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const offset_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm);
    const host_fd: posix.fd_t = if (wasi) |w| w.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    } else if (fd >= 0 and fd <= 2) {
        try pushErrno(vm, .SPIPE);
        return;
    } else {
        try pushErrno(vm, .BADF);
        return;
    };

    const cur = posix.lseek_CUR_get(host_fd) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };

    const memory = try vm.getMemory(0);
    try memory.write(u64, offset_ptr, 0, cur);
    try pushErrno(vm, .SUCCESS);
}

/// fd_readdir(fd: i32, buf_ptr: i32, buf_len: i32, cookie: i64, bufused_ptr: i32) -> errno
pub fn fd_readdir(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const bufused_ptr = vm.popOperandU32();
    _ = vm.popOperandI64(); // cookie
    _ = vm.popOperandU32(); // buf_len
    _ = vm.popOperandU32(); // buf_ptr
    _ = vm.popOperandI32(); // fd

    // Stub: return empty directory
    const memory = try vm.getMemory(0);
    try memory.write(u32, bufused_ptr, 0, 0);
    try pushErrno(vm, .SUCCESS);
}

/// path_filestat_get(fd: i32, flags: i32, path_ptr: i32, path_len: i32, filestat_ptr: i32) -> errno
pub fn path_filestat_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const filestat_ptr = vm.popOperandU32();
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    _ = vm.popOperandU32(); // flags
    _ = vm.popOperandI32(); // fd

    _ = path_ptr;
    _ = path_len;

    // Stub: zero-fill filestat
    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (filestat_ptr + 64 > data.len) return error.OutOfBoundsMemoryAccess;
    @memset(data[filestat_ptr .. filestat_ptr + 64], 0);
    data[filestat_ptr + 16] = @intFromEnum(Filetype.REGULAR_FILE);

    try pushErrno(vm, .SUCCESS);
}

/// path_open(fd:i32, dirflags:i32, path_ptr:i32, path_len:i32, oflags:i32, rights_base:i64, rights_inh:i64, fdflags:i32, opened_fd_ptr:i32) -> errno
pub fn path_open(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const opened_fd_ptr = vm.popOperandU32();
    _ = vm.popOperandU32(); // fdflags
    _ = vm.popOperandI64(); // rights_inheriting
    _ = vm.popOperandI64(); // rights_base
    _ = vm.popOperandU32(); // oflags
    _ = vm.popOperandU32(); // path_len
    _ = vm.popOperandU32(); // path_ptr
    _ = vm.popOperandU32(); // dirflags
    _ = vm.popOperandI32(); // fd

    _ = opened_fd_ptr;

    // Stub: filesystem access not yet implemented
    try pushErrno(vm, .NOENT);
}

/// proc_exit(exit_code: i32) -> noreturn (via Trap)
pub fn proc_exit(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const exit_code = vm.popOperandU32();

    if (getWasi(vm)) |wasi| {
        wasi.exit_code = exit_code;
    }
    return error.Trap;
}

/// random_get(buf_ptr: i32, buf_len: i32) -> errno
pub fn random_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const buf_len = vm.popOperandU32();
    const buf_ptr = vm.popOperandU32();

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    if (buf_ptr + buf_len > data.len) return error.OutOfBoundsMemoryAccess;

    std.crypto.random.bytes(data[buf_ptr .. buf_ptr + buf_len]);

    try pushErrno(vm, .SUCCESS);
}

/// clock_res_get(clock_id: i32, resolution_ptr: i32) -> errno
pub fn clock_res_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const resolution_ptr = vm.popOperandU32();
    const clock_id = vm.popOperandU32();

    const memory = try vm.getMemory(0);

    // Return nanosecond resolution for all clocks
    const resolution: u64 = switch (@as(ClockId, @enumFromInt(clock_id))) {
        .REALTIME => 1_000, // microsecond resolution
        .MONOTONIC => 1, // nanosecond resolution
        .PROCESS_CPUTIME, .THREAD_CPUTIME => 1_000, // microsecond resolution
    };
    try memory.write(u64, resolution_ptr, 0, resolution);

    try pushErrno(vm, .SUCCESS);
}

/// fd_datasync(fd: i32) -> errno
pub fn fd_datasync(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const fd = vm.popOperandI32();

    if (fd <= 2) {
        try pushErrno(vm, .INVAL);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    if (wasi.getHostFd(fd)) |host_fd| {
        posix.fdatasync(host_fd) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        };
        try pushErrno(vm, .SUCCESS);
    } else {
        try pushErrno(vm, .BADF);
    }
}

/// fd_sync(fd: i32) -> errno
pub fn fd_sync(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const fd = vm.popOperandI32();

    if (fd <= 2) {
        try pushErrno(vm, .INVAL);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    if (wasi.getHostFd(fd)) |host_fd| {
        posix.fsync(host_fd) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        };
        try pushErrno(vm, .SUCCESS);
    } else {
        try pushErrno(vm, .BADF);
    }
}

/// path_create_directory(fd: i32, path_ptr: i32, path_len: i32) -> errno
pub fn path_create_directory(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;
    const path = data[path_ptr .. path_ptr + path_len];

    posix.mkdirat(host_fd, path, 0o777) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try pushErrno(vm, .SUCCESS);
}

/// path_remove_directory(fd: i32, path_ptr: i32, path_len: i32) -> errno
pub fn path_remove_directory(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;
    const path = data[path_ptr .. path_ptr + path_len];

    posix.unlinkat(host_fd, path, posix.AT.REMOVEDIR) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try pushErrno(vm, .SUCCESS);
}

/// path_unlink_file(fd: i32, path_ptr: i32, path_len: i32) -> errno
pub fn path_unlink_file(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;
    const path = data[path_ptr .. path_ptr + path_len];

    posix.unlinkat(host_fd, path, 0) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try pushErrno(vm, .SUCCESS);
}

/// path_rename(fd: i32, old_path_ptr: i32, old_path_len: i32, new_fd: i32, new_path_ptr: i32, new_path_len: i32) -> errno
pub fn path_rename(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const new_path_len = vm.popOperandU32();
    const new_path_ptr = vm.popOperandU32();
    const new_fd = vm.popOperandI32();
    const old_path_len = vm.popOperandU32();
    const old_path_ptr = vm.popOperandU32();
    const old_fd = vm.popOperandI32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const old_host_fd = wasi.getHostFd(old_fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };
    const new_host_fd = wasi.getHostFd(new_fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (old_path_ptr + old_path_len > data.len) return error.OutOfBoundsMemoryAccess;
    if (new_path_ptr + new_path_len > data.len) return error.OutOfBoundsMemoryAccess;
    const old_path = data[old_path_ptr .. old_path_ptr + old_path_len];
    const new_path = data[new_path_ptr .. new_path_ptr + new_path_len];

    posix.renameat(old_host_fd, old_path, new_host_fd, new_path) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try pushErrno(vm, .SUCCESS);
}

/// sched_yield() -> errno
pub fn sched_yield(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    // Trivial yield — just return success
    // On most platforms, a simple yield is a no-op for single-threaded Wasm
    try pushErrno(vm, .SUCCESS);
}

/// fd_advise(fd: i32, offset: i64, len: i64, advice: i32) -> errno
pub fn fd_advise(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandU32(); // advice
    _ = vm.popOperandI64(); // len
    _ = vm.popOperandI64(); // offset
    _ = vm.popOperandI32(); // fd
    // Advisory only — no-op is valid
    try pushErrno(vm, .SUCCESS);
}

/// fd_allocate(fd: i32, offset: i64, len: i64) -> errno
pub fn fd_allocate(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandI64(); // len
    _ = vm.popOperandI64(); // offset
    _ = vm.popOperandI32(); // fd
    // fallocate not portable — stub as NOSYS
    try pushErrno(vm, .NOSYS);
}

/// fd_fdstat_set_flags(fd: i32, flags: i32) -> errno
pub fn fd_fdstat_set_flags(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandU32(); // flags
    _ = vm.popOperandI32(); // fd
    // Stub — flags modification not commonly needed
    try pushErrno(vm, .SUCCESS);
}

/// fd_filestat_set_size(fd: i32, size: i64) -> errno
pub fn fd_filestat_set_size(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const size = vm.popOperandI64();
    const fd = vm.popOperandI32();

    if (fd <= 2) {
        try pushErrno(vm, .INVAL);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    if (wasi.getHostFd(fd)) |host_fd| {
        posix.ftruncate(host_fd, @bitCast(size)) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        };
        try pushErrno(vm, .SUCCESS);
    } else {
        try pushErrno(vm, .BADF);
    }
}

/// fd_filestat_set_times(fd: i32, atim: i64, mtim: i64, fst_flags: i32) -> errno
pub fn fd_filestat_set_times(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandU32(); // fst_flags
    _ = vm.popOperandI64(); // mtim
    _ = vm.popOperandI64(); // atim
    _ = vm.popOperandI32(); // fd
    // Stub — timestamp modification not commonly needed
    try pushErrno(vm, .SUCCESS);
}

/// fd_pread(fd: i32, iovs_ptr: i32, iovs_len: i32, offset: i64, nread_ptr: i32) -> errno
pub fn fd_pread(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const nread_ptr = vm.popOperandU32();
    const file_offset = vm.popOperandI64();
    const iovs_len = vm.popOperandU32();
    const iovs_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm);
    const host_fd: posix.fd_t = if (wasi) |w| w.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    } else if (fd >= 0 and fd <= 2) @intCast(fd) else {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    var total: u32 = 0;
    var cur_offset: u64 = @bitCast(file_offset);
    for (0..iovs_len) |i| {
        const offset: u32 = @intCast(i * 8);
        const iov_ptr = try memory.read(u32, iovs_ptr, offset);
        const iov_len = try memory.read(u32, iovs_ptr, offset + 4);
        if (iov_ptr + iov_len > data.len) return error.OutOfBoundsMemoryAccess;

        const buf = data[iov_ptr .. iov_ptr + iov_len];
        const n = posix.pread(host_fd, buf, cur_offset) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        };
        total += @intCast(n);
        cur_offset += n;
        if (n < buf.len) break;
    }

    try memory.write(u32, nread_ptr, 0, total);
    try pushErrno(vm, .SUCCESS);
}

/// fd_pwrite(fd: i32, iovs_ptr: i32, iovs_len: i32, offset: i64, nwritten_ptr: i32) -> errno
pub fn fd_pwrite(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const nwritten_ptr = vm.popOperandU32();
    const file_offset = vm.popOperandI64();
    const iovs_len = vm.popOperandU32();
    const iovs_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm);
    const host_fd: posix.fd_t = if (wasi) |w| w.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    } else if (fd >= 0 and fd <= 2) @intCast(fd) else {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    var total: u32 = 0;
    var cur_offset: u64 = @bitCast(file_offset);
    for (0..iovs_len) |i| {
        const offset: u32 = @intCast(i * 8);
        const iov_ptr = try memory.read(u32, iovs_ptr, offset);
        const iov_len = try memory.read(u32, iovs_ptr, offset + 4);
        if (iov_ptr + iov_len > data.len) return error.OutOfBoundsMemoryAccess;

        const buf = data[iov_ptr .. iov_ptr + iov_len];
        const n = posix.pwrite(host_fd, buf, cur_offset) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        };
        total += @intCast(n);
        cur_offset += n;
        if (n < buf.len) break;
    }

    try memory.write(u32, nwritten_ptr, 0, total);
    try pushErrno(vm, .SUCCESS);
}

/// fd_renumber(fd_from: i32, fd_to: i32) -> errno
pub fn fd_renumber(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const fd_to = vm.popOperandI32();
    const fd_from = vm.popOperandI32();

    _ = fd_to;
    _ = fd_from;

    // dup2 equivalent — stub for now
    try pushErrno(vm, .NOSYS);
}

/// path_filestat_set_times(fd: i32, flags: i32, path_ptr: i32, path_len: i32, atim: i64, mtim: i64, fst_flags: i32) -> errno
pub fn path_filestat_set_times(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandU32(); // fst_flags
    _ = vm.popOperandI64(); // mtim
    _ = vm.popOperandI64(); // atim
    _ = vm.popOperandU32(); // path_len
    _ = vm.popOperandU32(); // path_ptr
    _ = vm.popOperandU32(); // flags
    _ = vm.popOperandI32(); // fd
    // Stub — timestamp modification
    try pushErrno(vm, .SUCCESS);
}

/// path_readlink(fd: i32, path_ptr: i32, path_len: i32, buf_ptr: i32, buf_len: i32, bufused_ptr: i32) -> errno
pub fn path_readlink(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const bufused_ptr = vm.popOperandU32();
    const buf_len = vm.popOperandU32();
    const buf_ptr = vm.popOperandU32();
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;
    if (buf_ptr + buf_len > data.len) return error.OutOfBoundsMemoryAccess;

    const path = data[path_ptr .. path_ptr + path_len];
    const buf = data[buf_ptr .. buf_ptr + buf_len];

    const result = posix.readlinkat(host_fd, path, buf) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try memory.write(u32, bufused_ptr, 0, @intCast(result.len));
    try pushErrno(vm, .SUCCESS);
}

/// path_symlink(old_path_ptr: i32, old_path_len: i32, fd: i32, new_path_ptr: i32, new_path_len: i32) -> errno
pub fn path_symlink(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandU32(); // new_path_len
    _ = vm.popOperandU32(); // new_path_ptr
    _ = vm.popOperandI32(); // fd
    _ = vm.popOperandU32(); // old_path_len
    _ = vm.popOperandU32(); // old_path_ptr
    // symlinkat not in std.posix — stub as NOSYS
    try pushErrno(vm, .NOSYS);
}

// ============================================================
// Error mapping
// ============================================================

fn toWasiErrno(err: anyerror) Errno {
    return switch (err) {
        error.AccessDenied => .ACCES,
        error.BrokenPipe => .PIPE,
        error.FileTooBig => .FBIG,
        error.InputOutput => .IO,
        error.IsDir => .ISDIR,
        error.NoSpaceLeft => .NOSPC,
        error.PermissionDenied => .PERM,
        error.Unseekable => .SPIPE,
        error.NotOpenForReading => .BADF,
        error.NotOpenForWriting => .BADF,
        error.FileNotFound => .NOENT,
        error.PathAlreadyExists => .EXIST,
        error.NotDir => .NOTDIR,
        error.DirNotEmpty => .NOTEMPTY,
        error.NameTooLong => .NAMETOOLONG,
        error.FileBusy => .BUSY,
        error.DiskQuota => .DQUOT,
        error.SymLinkLoop => .LOOP,
        error.ReadOnlyFileSystem => .ROFS,
        else => .IO,
    };
}

// ============================================================
// Registration — register WASI functions for module imports
// ============================================================

const WasiEntry = struct {
    name: []const u8,
    func: store_mod.HostFn,
};

const wasi_table = [_]WasiEntry{
    .{ .name = "args_get", .func = &args_get },
    .{ .name = "args_sizes_get", .func = &args_sizes_get },
    .{ .name = "clock_res_get", .func = &clock_res_get },
    .{ .name = "clock_time_get", .func = &clock_time_get },
    .{ .name = "environ_get", .func = &environ_get },
    .{ .name = "environ_sizes_get", .func = &environ_sizes_get },
    .{ .name = "fd_advise", .func = &fd_advise },
    .{ .name = "fd_allocate", .func = &fd_allocate },
    .{ .name = "fd_close", .func = &fd_close },
    .{ .name = "fd_datasync", .func = &fd_datasync },
    .{ .name = "fd_fdstat_get", .func = &fd_fdstat_get },
    .{ .name = "fd_fdstat_set_flags", .func = &fd_fdstat_set_flags },
    .{ .name = "fd_filestat_get", .func = &fd_filestat_get },
    .{ .name = "fd_filestat_set_size", .func = &fd_filestat_set_size },
    .{ .name = "fd_filestat_set_times", .func = &fd_filestat_set_times },
    .{ .name = "fd_pread", .func = &fd_pread },
    .{ .name = "fd_prestat_get", .func = &fd_prestat_get },
    .{ .name = "fd_prestat_dir_name", .func = &fd_prestat_dir_name },
    .{ .name = "fd_pwrite", .func = &fd_pwrite },
    .{ .name = "fd_read", .func = &fd_read },
    .{ .name = "fd_readdir", .func = &fd_readdir },
    .{ .name = "fd_renumber", .func = &fd_renumber },
    .{ .name = "fd_seek", .func = &fd_seek },
    .{ .name = "fd_sync", .func = &fd_sync },
    .{ .name = "fd_tell", .func = &fd_tell },
    .{ .name = "fd_write", .func = &fd_write },
    .{ .name = "path_create_directory", .func = &path_create_directory },
    .{ .name = "path_filestat_get", .func = &path_filestat_get },
    .{ .name = "path_filestat_set_times", .func = &path_filestat_set_times },
    .{ .name = "path_open", .func = &path_open },
    .{ .name = "path_readlink", .func = &path_readlink },
    .{ .name = "path_remove_directory", .func = &path_remove_directory },
    .{ .name = "path_rename", .func = &path_rename },
    .{ .name = "path_symlink", .func = &path_symlink },
    .{ .name = "path_unlink_file", .func = &path_unlink_file },
    .{ .name = "proc_exit", .func = &proc_exit },
    .{ .name = "random_get", .func = &random_get },
    .{ .name = "sched_yield", .func = &sched_yield },
};

fn lookupWasiFunc(name: []const u8) ?store_mod.HostFn {
    for (&wasi_table) |*entry| {
        if (mem.eql(u8, entry.name, name)) return entry.func;
    }
    return null;
}

/// Register WASI functions that the module imports from "wasi_snapshot_preview1".
pub fn registerAll(store: *Store, module: *const Module) !void {
    for (module.imports.items) |imp| {
        if (imp.kind != .func) continue;
        if (!mem.eql(u8, imp.module, "wasi_snapshot_preview1")) continue;

        const func_ptr = lookupWasiFunc(imp.name) orelse continue;

        // Get type from module
        if (imp.index >= module.types.items.len) return error.InvalidTypeIndex;
        const func_type = module.types.items[imp.index];

        try store.exposeHostFunction(
            imp.module,
            imp.name,
            func_ptr,
            0,
            func_type.params,
            func_type.results,
        );
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn readTestFile(name: []const u8) ![]const u8 {
    const paths = [_][]const u8{
        "src/wasm/testdata/",
        "testdata/",
    };
    for (&paths) |prefix| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ prefix, name });
        defer testing.allocator.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch continue;
        defer file.close();
        const stat = try file.stat();
        const data = try testing.allocator.alloc(u8, stat.size);
        const n = try file.readAll(data);
        return data[0..n];
    }
    return error.FileNotFound;
}

test "WASI — fd_write via 07_wasi_hello.wasm" {
    const alloc = testing.allocator;

    // Load and decode module
    const wasm_bytes = try readTestFile("07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    // Create store and register WASI
    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    // Instantiate
    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    // Set up WASI context
    var wasi_ctx = WasiContext.init(alloc);
    defer wasi_ctx.deinit();
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    // Create pipe for capturing stdout
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);

    // Redirect stdout to pipe write end
    const saved_stdout = try posix.dup(1);
    defer posix.close(saved_stdout);
    try posix.dup2(pipe[1], 1);
    posix.close(pipe[1]);

    // Run _start
    var vm_inst = Vm.init(alloc);
    var results: [0]u64 = .{};
    vm_inst.invoke(&instance, "_start", &.{}, &results) catch |err| {
        // proc_exit or normal completion
        if (err != error.Trap) return err;
    };

    // Restore stdout
    try posix.dup2(saved_stdout, 1);

    // Read captured output
    var buf: [256]u8 = undefined;
    const n = try posix.read(pipe[0], &buf);
    const output = buf[0..n];

    try testing.expectEqualStrings("Hello, WASI!\n", output);
}

test "WASI — args_sizes_get and args_get" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile("07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc);
    defer wasi_ctx.deinit();

    const test_args = [_][:0]const u8{ "prog", "arg1", "arg2" };
    wasi_ctx.setArgs(&test_args);
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    // Manually test args_sizes_get via direct call
    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;
    const memory = try instance.getMemory(0);

    // Push args (argv_buf_size_ptr=104, argc_ptr=100)
    try vm_inst.pushOperand(100); // argc_ptr
    try vm_inst.pushOperand(104); // argv_buf_size_ptr

    // Call args_sizes_get
    try args_sizes_get(@ptrCast(&vm_inst), 0);

    // Check errno
    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, 0), errno); // SUCCESS

    // Check argc
    const argc = try memory.read(u32, 100, 0);
    try testing.expectEqual(@as(u32, 3), argc);

    // Check buf_size: "prog\0" + "arg1\0" + "arg2\0" = 5 + 5 + 5 = 15
    const buf_size = try memory.read(u32, 104, 0);
    try testing.expectEqual(@as(u32, 15), buf_size);
}

test "WASI — environ_sizes_get with empty environ" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile("07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc);
    defer wasi_ctx.deinit();
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;

    try vm_inst.pushOperand(200); // count_ptr
    try vm_inst.pushOperand(204); // buf_size_ptr

    try environ_sizes_get(@ptrCast(&vm_inst), 0);

    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, 0), errno);

    const memory = try instance.getMemory(0);
    const count = try memory.read(u32, 200, 0);
    try testing.expectEqual(@as(u32, 0), count);

    const buf_size = try memory.read(u32, 204, 0);
    try testing.expectEqual(@as(u32, 0), buf_size);
}

test "WASI — clock_time_get returns nonzero" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile("07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc);
    defer wasi_ctx.deinit();
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;

    // clock_time_get(clock_id=0, precision=0, time_ptr=300)
    try vm_inst.pushOperand(0); // clock_id = REALTIME
    try vm_inst.pushOperand(0); // precision
    try vm_inst.pushOperand(300); // time_ptr

    try clock_time_get(@ptrCast(&vm_inst), 0);

    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, 0), errno);

    const memory = try instance.getMemory(0);
    const time_val = try memory.read(u64, 300, 0);
    try testing.expect(time_val > 0);
}

test "WASI — random_get fills buffer" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile("07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc);
    defer wasi_ctx.deinit();
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;

    const memory = try instance.getMemory(0);
    const data = memory.memory();

    // Zero-fill target area
    @memset(data[400..416], 0);

    // random_get(buf_ptr=400, buf_len=16)
    try vm_inst.pushOperand(400); // buf_ptr
    try vm_inst.pushOperand(16); // buf_len

    try random_get(@ptrCast(&vm_inst), 0);

    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, 0), errno);

    // Very unlikely all 16 bytes remain zero after random fill
    var all_zero = true;
    for (data[400..416]) |b| {
        if (b != 0) { all_zero = false; break; }
    }
    try testing.expect(!all_zero);
}

test "WASI — registerAll for wasi_hello module" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile("07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    // Should have registered fd_write
    try testing.expectEqual(@as(usize, 1), store_inst.functions.items.len);
}
