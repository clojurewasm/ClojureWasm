// SPDX-License-Identifier: EPL-2.0
//! Terminal line editor for the interactive REPL.
//!
//! Pure-Zig (no external dependency) raw-mode line editor adapted from
//! cw v0 for Zig 0.16. Features: emacs keybindings (C-a/C-e/C-b/C-f/
//! C-k/C-u/C-w/C-y/C-d/C-l), escape-sequence arrows mapped to history
//! browse + cursor move, a 1000-entry in-memory history with an
//! optional persistent `$HOME/.cljw_history` file, multi-line
//! continuation while delimiters are unbalanced, and tab completion
//! over the live Env's symbols.
//!
//! ### I/O contract
//!
//! Input is read **byte-at-a-time** from the raw stdin fd
//! (`std.Io.File.stdin().handle`) via `std.posix.read` — the REPL's
//! buffered reader is bypassed because raw mode is byte-granular.
//! Output is written to the `*std.Io.Writer` the REPL already threads
//! as its stdout; `readInput` flushes after every redraw so the
//! terminal stays in sync. The editor borrows the writer; it does not
//! own it.
//!
//! ### Lifetime
//!
//! `init` reads `$HOME` + loads the history file (allocator-owned
//! dup'd strings). `deinit` restores the original termios and frees
//! every history string + the resolved history path. The edit / yank /
//! saved-input buffers are fixed arrays inside the struct — no
//! per-keystroke allocation.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const Env = @import("../../runtime/env.zig").Env;
const introspect = @import("../../runtime/introspect.zig");
const process_env = @import("../../runtime/process_env.zig");

/// A decoded key event. Escape sequences and control bytes are
/// normalised here so `readInput`'s dispatch is a flat switch.
pub const Key = union(enum) {
    char: u8,
    ctrl: u8, // C-a => 'a', C-e => 'e', ...
    alt: u8, // Alt-f / Alt-b / Alt-d
    enter,
    alt_enter,
    tab,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    eof, // read error / fd closed
    unknown,
};

pub const LineEditor = struct {
    // Terminal state.
    orig_termios: posix.termios,
    fd: posix.fd_t,
    out: *Writer,
    io: Io, // threaded for the persistent-history file ops
    raw_mode: bool,

    // Edit buffer (single line, or multi-line joined by '\n').
    buf: [max_buf]u8,
    len: usize,
    pos: usize, // cursor byte position in buf

    // Yank buffer (C-k / C-u / C-w / Alt-d fill it; C-y pastes).
    yank_buf: [max_buf]u8,
    yank_len: usize,

    // History ring + browse cursor.
    history: [max_history]?[]const u8,
    history_len: usize,
    history_idx: usize, // browse index; == history_len means "current input"
    saved_input: [max_buf]u8, // current input parked while browsing history
    saved_input_len: usize,

    // Persistent history file path ($HOME/.cljw_history), allocator-owned.
    history_path: ?[]const u8,

    // Tab completion source (the live session Env), or null to disable.
    env: ?*Env,

    allocator: Allocator,

    // Prompt + continuation prompt (rebuilt by setNsPrompt each readInput).
    prompt: []const u8,
    cont_prompt: []const u8,
    prompt_display_len: usize, // visible width (ANSI escapes excluded)
    prompt_buf: [256]u8,
    cont_prompt_buf: [256]u8,

    // Terminal cursor row after the last redraw (0-based from the first
    // rendered line) — drives the "move up N then clear" of the next redraw.
    prev_cursor_row: usize,

    const max_buf = 65536;
    const max_history = 1000;

    /// Borrow `out` for the editor's lifetime; `env` may be null to
    /// disable tab completion. `io` is threaded for the persistent
    /// history file ops. Reads `$HOME` and loads the persistent history
    /// file (best-effort — a missing file is fine).
    pub fn init(allocator: Allocator, io: Io, out: *Writer, env: ?*Env) LineEditor {
        var self = LineEditor{
            .orig_termios = undefined,
            .fd = std.Io.File.stdin().handle,
            .out = out,
            .io = io,
            .raw_mode = false,
            .buf = undefined,
            .len = 0,
            .pos = 0,
            .yank_buf = undefined,
            .yank_len = 0,
            .history = [_]?[]const u8{null} ** max_history,
            .history_len = 0,
            .history_idx = 0,
            .saved_input = undefined,
            .saved_input_len = 0,
            .history_path = null,
            .env = env,
            .allocator = allocator,
            .prompt = "user=> ",
            .cont_prompt = "",
            .prompt_display_len = 7,
            .prompt_buf = undefined,
            .cont_prompt_buf = undefined,
            .prev_cursor_row = 0,
        };
        self.resolveHistoryPath();
        self.loadHistory();
        return self;
    }

    pub fn deinit(self: *LineEditor) void {
        self.disableRawMode();
        self.saveHistory();
        for (&self.history) |*entry| {
            if (entry.*) |s| {
                self.allocator.free(s);
                entry.* = null;
            }
        }
        if (self.history_path) |p| self.allocator.free(p);
        self.history_path = null;
    }

    /// Refresh the prompt to reflect the current namespace. Call from
    /// the REPL loop before each `readInput`. Builds a green-coloured
    /// `<ns>=> ` prompt plus a width-matched blank continuation prompt.
    pub fn setNsPrompt(self: *LineEditor, ns_name: []const u8) void {
        var w: Writer = .fixed(&self.prompt_buf);
        w.writeAll("\x1b[32m") catch return; // green
        w.writeAll(ns_name) catch return;
        w.writeAll("\x1b[0m=> ") catch return;
        self.prompt = w.buffered();
        // Visible width excludes the ANSI codes: ns name + "=> ".
        self.prompt_display_len = ns_name.len + 3;

        var cw: Writer = .fixed(&self.cont_prompt_buf);
        var i: usize = 0;
        while (i < self.prompt_display_len) : (i += 1) cw.writeByte(' ') catch return;
        self.cont_prompt = cw.buffered();
    }

    /// Read one complete expression from the terminal. Returns a slice
    /// into the internal buffer (valid until the next `readInput`), or
    /// null on EOF (Ctrl-D on an empty line / closed stdin). Keeps
    /// reading across newlines while delimiters are unbalanced so a
    /// multi-line form arrives as a single string.
    pub fn readInput(self: *LineEditor) ?[]const u8 {
        self.len = 0;
        self.pos = 0;
        self.prev_cursor_row = 0;

        while (true) {
            self.enableRawMode();
            self.refresh();

            const key = self.readKey();
            switch (key) {
                .eof => {
                    self.disableRawMode();
                    if (self.len == 0) return null;
                    break; // non-empty buffer + EOF acts like Enter
                },
                .enter => {
                    if (countDelimiterDepth(self.buf[0..self.len]) > 0) {
                        self.insertChar('\n'); // continuation
                        continue;
                    }
                    self.disableRawMode();
                    self.writeStr("\r\n");
                    break;
                },
                .alt_enter => {
                    self.insertChar('\n'); // force newline regardless of depth
                    continue;
                },
                .tab => self.handleTab(),
                .backspace => self.deleteBack(),
                .delete => self.deleteForward(),
                .left => self.moveLeft(),
                .right => self.moveRight(),
                .up => self.historyPrev(),
                .down => self.historyNext(),
                .home => self.moveHome(),
                .end => self.moveEnd(),
                .ctrl => |c| switch (c) {
                    'a' => self.moveHome(),
                    'e' => self.moveEnd(),
                    'f' => self.moveRight(),
                    'b' => self.moveLeft(),
                    'k' => self.killToEnd(),
                    'u' => self.killToStart(),
                    'w' => self.killWordBack(),
                    'y' => self.yank(),
                    'h' => self.deleteBack(), // C-h == backspace
                    'o' => self.insertChar('\n'), // force newline
                    'p' => self.historyPrev(),
                    'n' => self.historyNext(),
                    'd' => {
                        if (self.len == 0) {
                            self.disableRawMode();
                            return null; // C-d on empty line == EOF
                        }
                        self.deleteForward();
                    },
                    'c' => {
                        // Abandon the current line, print ^C, fresh prompt.
                        self.disableRawMode();
                        self.writeStr("^C\r\n");
                        self.len = 0;
                        self.pos = 0;
                        self.prev_cursor_row = 0;
                    },
                    'l' => {
                        self.writeStr("\x1b[2J\x1b[H"); // clear screen
                        self.prev_cursor_row = 0;
                    },
                    else => {},
                },
                .alt => |c| switch (c) {
                    'f' => self.moveWordForward(),
                    'b' => self.moveWordBack(),
                    'd' => self.killWordForward(),
                    else => {},
                },
                .char => |c| self.insertChar(c),
                .unknown => {},
            }
        }

        if (self.len == 0) return null;
        const input = self.buf[0..self.len];
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len > 0) self.addHistory(trimmed);
        return input;
    }

    // --- raw mode ---

    fn enableRawMode(self: *LineEditor) void {
        if (self.raw_mode) return;
        self.orig_termios = posix.tcgetattr(self.fd) catch return;
        var raw = self.orig_termios;
        // Input: no break interrupt, no CR->NL, no parity / strip / flow ctrl.
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        // Output: no post-processing (we emit \r\n ourselves).
        raw.oflag.OPOST = false;
        // Local: no echo / canonical / extended / signal-gen.
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        // read() returns after 1 byte, no inter-byte timeout.
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        posix.tcsetattr(self.fd, .FLUSH, raw) catch return;
        self.raw_mode = true;
    }

    fn disableRawMode(self: *LineEditor) void {
        if (!self.raw_mode) return;
        // Best-effort restore — nothing actionable if the tty vanished.
        posix.tcsetattr(self.fd, .FLUSH, self.orig_termios) catch {};
        self.raw_mode = false;
    }

    // --- key reading ---

    fn readByte(self: *LineEditor) ?u8 {
        var b: [1]u8 = undefined;
        const n = posix.read(self.fd, b[0..1]) catch return null;
        if (n == 0) return null;
        return b[0];
    }

    /// Read a byte with a ~100 ms timeout for ESC-sequence
    /// disambiguation (a bare ESC vs the start of `ESC [ A`). Swaps the
    /// fd to VMIN=0/VTIME=1, reads, then restores the blocking cc.
    fn readByteTimeout(self: *LineEditor) ?u8 {
        var raw = posix.tcgetattr(self.fd) catch return null;
        const saved_min = raw.cc[@intFromEnum(posix.V.MIN)];
        const saved_time = raw.cc[@intFromEnum(posix.V.TIME)];
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1; // 1 decisecond
        posix.tcsetattr(self.fd, .NOW, raw) catch return null;
        defer {
            raw.cc[@intFromEnum(posix.V.MIN)] = saved_min;
            raw.cc[@intFromEnum(posix.V.TIME)] = saved_time;
            posix.tcsetattr(self.fd, .NOW, raw) catch {};
        }
        var b: [1]u8 = undefined;
        const n = posix.read(self.fd, b[0..1]) catch return null;
        if (n == 0) return null;
        return b[0];
    }

    fn readKey(self: *LineEditor) Key {
        const c = self.readByte() orelse return .eof;
        switch (c) {
            '\r', '\n' => return .enter,
            '\t' => return .tab,
            127 => return .backspace,
            1...8, 11...12, 14...26 => |ctrl| {
                // Ctrl-A..Ctrl-Z, skipping \t(9) \n(10) \r(13).
                return .{ .ctrl = ctrl + 'a' - 1 };
            },
            27 => { // ESC
                const next = self.readByteTimeout() orelse return .unknown;
                switch (next) {
                    '[' => return self.readCsiSequence(),
                    'O' => return self.readSsSequence(),
                    '\r', '\n' => return .alt_enter,
                    'a'...'z' => return .{ .alt = next },
                    // Uppercase Alt-<letter> normalised to lowercase; 'O' is
                    // excluded — bare `ESC O` is the SS3 prefix handled above.
                    'A'...'N', 'P'...'Z' => return .{ .alt = next + 32 },
                    else => return .unknown,
                }
            },
            ' '...126 => return .{ .char = c },
            // UTF-8 lead/continuation bytes are inserted as raw bytes; the
            // editor's column math is ASCII-only but the bytes round-trip.
            128...255 => return .{ .char = c },
            else => return .unknown,
        }
    }

    fn readCsiSequence(self: *LineEditor) Key {
        const first = self.readByteTimeout() orelse return .unknown;
        switch (first) {
            'A' => return .up,
            'B' => return .down,
            'C' => return .right,
            'D' => return .left,
            'H' => return .home,
            'F' => return .end,
            '0'...'9' => {
                // Extended: ESC [ <num> (; <num>)* (~ | u).
                var params: [4]u32 = .{ 0, 0, 0, 0 };
                params[0] = first - '0';
                var param_count: usize = 1;
                var guard: usize = 0;
                while (guard < 16) : (guard += 1) {
                    const b = self.readByteTimeout() orelse return .unknown;
                    switch (b) {
                        '0'...'9' => params[param_count - 1] = params[param_count - 1] * 10 + (b - '0'),
                        ';' => if (param_count < params.len) {
                            param_count += 1;
                        },
                        '~' => {
                            if (params[0] == 3) return .delete;
                            if (params[0] == 1) return .home;
                            if (params[0] == 4) return .end;
                            return .unknown;
                        },
                        'u' => {
                            // CSI u (kitty): ESC [ 13 ; 2 u == Shift-Enter.
                            if (params[0] == 13 and param_count >= 2 and params[1] == 2) return .alt_enter;
                            return .unknown;
                        },
                        else => return .unknown,
                    }
                }
                return .unknown;
            },
            else => return .unknown,
        }
    }

    fn readSsSequence(self: *LineEditor) Key {
        const c = self.readByteTimeout() orelse return .unknown;
        return switch (c) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => .unknown,
        };
    }

    // --- edit operations ---

    fn insertChar(self: *LineEditor, c: u8) void {
        if (self.len >= max_buf - 1) return;
        if (self.pos < self.len) {
            std.mem.copyBackwards(u8, self.buf[self.pos + 1 .. self.len + 1], self.buf[self.pos..self.len]);
        }
        self.buf[self.pos] = c;
        self.pos += 1;
        self.len += 1;
    }

    fn deleteBack(self: *LineEditor) void {
        if (self.pos == 0) return;
        if (self.pos < self.len) {
            std.mem.copyForwards(u8, self.buf[self.pos - 1 .. self.len - 1], self.buf[self.pos..self.len]);
        }
        self.pos -= 1;
        self.len -= 1;
    }

    fn deleteForward(self: *LineEditor) void {
        if (self.pos >= self.len) return;
        if (self.pos + 1 < self.len) {
            std.mem.copyForwards(u8, self.buf[self.pos .. self.len - 1], self.buf[self.pos + 1 .. self.len]);
        }
        self.len -= 1;
    }

    fn moveLeft(self: *LineEditor) void {
        if (self.pos > 0) self.pos -= 1;
    }

    fn moveRight(self: *LineEditor) void {
        if (self.pos < self.len) self.pos += 1;
    }

    fn moveHome(self: *LineEditor) void {
        // Start of the current visual line (after the last '\n' before pos).
        if (self.pos == 0) return;
        var i = self.pos - 1;
        while (i > 0 and self.buf[i] != '\n') : (i -= 1) {}
        self.pos = if (self.buf[i] == '\n') i + 1 else 0;
    }

    fn moveEnd(self: *LineEditor) void {
        while (self.pos < self.len and self.buf[self.pos] != '\n') self.pos += 1;
    }

    fn moveWordForward(self: *LineEditor) void {
        while (self.pos < self.len and !isWordChar(self.buf[self.pos])) self.pos += 1;
        while (self.pos < self.len and isWordChar(self.buf[self.pos])) self.pos += 1;
    }

    fn moveWordBack(self: *LineEditor) void {
        if (self.pos == 0) return;
        self.pos -= 1;
        while (self.pos > 0 and !isWordChar(self.buf[self.pos])) self.pos -= 1;
        while (self.pos > 0 and isWordChar(self.buf[self.pos - 1])) self.pos -= 1;
    }

    fn killToEnd(self: *LineEditor) void {
        var end = self.pos;
        while (end < self.len and self.buf[end] != '\n') end += 1;
        const killed = end - self.pos;
        if (killed == 0) return;
        @memcpy(self.yank_buf[0..killed], self.buf[self.pos..end]);
        self.yank_len = killed;
        if (end < self.len) {
            std.mem.copyForwards(u8, self.buf[self.pos .. self.len - killed], self.buf[end..self.len]);
        }
        self.len -= killed;
    }

    fn killToStart(self: *LineEditor) void {
        if (self.pos == 0) return;
        var start = self.pos - 1;
        while (start > 0 and self.buf[start - 1] != '\n') start -= 1;
        const killed = self.pos - start;
        if (killed == 0) return;
        @memcpy(self.yank_buf[0..killed], self.buf[start..self.pos]);
        self.yank_len = killed;
        std.mem.copyForwards(u8, self.buf[start .. self.len - killed], self.buf[self.pos..self.len]);
        self.len -= killed;
        self.pos = start;
    }

    fn killWordBack(self: *LineEditor) void {
        if (self.pos == 0) return;
        const orig = self.pos;
        while (self.pos > 0 and !isWordChar(self.buf[self.pos - 1])) self.pos -= 1;
        while (self.pos > 0 and isWordChar(self.buf[self.pos - 1])) self.pos -= 1;
        const killed = orig - self.pos;
        @memcpy(self.yank_buf[0..killed], self.buf[self.pos..orig]);
        self.yank_len = killed;
        std.mem.copyForwards(u8, self.buf[self.pos .. self.len - killed], self.buf[orig..self.len]);
        self.len -= killed;
    }

    fn killWordForward(self: *LineEditor) void {
        if (self.pos >= self.len) return;
        const orig = self.pos;
        while (self.pos < self.len and !isWordChar(self.buf[self.pos])) self.pos += 1;
        while (self.pos < self.len and isWordChar(self.buf[self.pos])) self.pos += 1;
        const killed = self.pos - orig;
        @memcpy(self.yank_buf[0..killed], self.buf[orig..self.pos]);
        self.yank_len = killed;
        if (self.pos < self.len) {
            std.mem.copyForwards(u8, self.buf[orig .. self.len - killed], self.buf[self.pos..self.len]);
        }
        self.len -= killed;
        self.pos = orig;
    }

    fn yank(self: *LineEditor) void {
        if (self.yank_len == 0 or self.len + self.yank_len >= max_buf) return;
        if (self.pos < self.len) {
            std.mem.copyBackwards(u8, self.buf[self.pos + self.yank_len .. self.len + self.yank_len], self.buf[self.pos..self.len]);
        }
        @memcpy(self.buf[self.pos .. self.pos + self.yank_len], self.yank_buf[0..self.yank_len]);
        self.pos += self.yank_len;
        self.len += self.yank_len;
    }

    // --- rendering ---

    /// Repaint the prompt + buffer and reposition the cursor. Composes
    /// the whole frame into a stack buffer, then writes + flushes once
    /// so the terminal never sees a partial redraw.
    fn refresh(self: *LineEditor) void {
        var out_buf: [8192]u8 = undefined;
        var w: Writer = .fixed(&out_buf);

        // Climb to the first line of the previous render, then clear down.
        if (self.prev_cursor_row > 0) w.print("\x1b[{d}A", .{self.prev_cursor_row}) catch return;
        w.writeAll("\r\x1b[J") catch return;

        const content = self.buf[0..self.len];
        var line_start: usize = 0;
        var line_idx: usize = 0;
        var cursor_row: usize = 0;
        var cursor_col: usize = 0;

        for (content, 0..) |ch, i| {
            if (i == self.pos) {
                cursor_row = line_idx;
                cursor_col = i - line_start;
            }
            if (ch == '\n') {
                const pr = if (line_idx == 0) self.prompt else self.cont_prompt;
                w.writeAll(pr) catch return;
                w.writeAll(content[line_start..i]) catch return;
                w.writeAll("\r\n") catch return;
                line_start = i + 1;
                line_idx += 1;
            }
        }
        if (self.pos == self.len) {
            cursor_row = line_idx;
            cursor_col = self.len - line_start;
        }
        const pr = if (line_idx == 0) self.prompt else self.cont_prompt;
        w.writeAll(pr) catch return;
        w.writeAll(content[line_start..]) catch return;

        // We are at the end of the last line: climb back up to the cursor
        // row, then over to the cursor column (prompt width + col).
        const lines_below = line_idx - cursor_row;
        if (lines_below > 0) w.print("\x1b[{d}A", .{lines_below}) catch return;
        const prompt_display = if (cursor_row == 0) self.prompt_display_len else self.cont_prompt.len;
        const col_offset = prompt_display + cursor_col;
        if (col_offset > 0) {
            w.print("\r\x1b[{d}C", .{col_offset}) catch return;
        } else {
            w.writeAll("\r") catch return;
        }

        self.prev_cursor_row = cursor_row;
        self.out.writeAll(w.buffered()) catch {};
        self.out.flush() catch {};
    }

    fn writeStr(self: *LineEditor, s: []const u8) void {
        self.out.writeAll(s) catch {};
        self.out.flush() catch {};
    }

    // --- history ---

    fn addHistory(self: *LineEditor, line: []const u8) void {
        // Collapse a consecutive duplicate.
        if (self.history_len > 0) {
            if (self.history[self.history_len - 1]) |last| {
                if (std.mem.eql(u8, last, line)) {
                    self.history_idx = self.history_len;
                    return;
                }
            }
        }
        const duped = self.allocator.dupe(u8, line) catch return;
        if (self.history_len < max_history) {
            self.history[self.history_len] = duped;
            self.history_len += 1;
        } else {
            if (self.history[0]) |oldest| self.allocator.free(oldest);
            for (0..max_history - 1) |i| self.history[i] = self.history[i + 1];
            self.history[max_history - 1] = duped;
        }
        self.history_idx = self.history_len;
        // Persistence is batched: the whole ring is flushed in `saveHistory`
        // at `deinit` (this 0.16 File API exposes neither append-mode nor
        // seek, so a per-line append would mean reopen+rewrite every Enter).
    }

    fn historyPrev(self: *LineEditor) void {
        if (self.history_len == 0 or self.history_idx == 0) return;
        if (self.history_idx == self.history_len) {
            // Park the in-progress line so historyNext can restore it.
            @memcpy(self.saved_input[0..self.len], self.buf[0..self.len]);
            self.saved_input_len = self.len;
        }
        self.history_idx -= 1;
        if (self.history[self.history_idx]) |entry| self.loadEntry(entry);
    }

    fn historyNext(self: *LineEditor) void {
        if (self.history_idx >= self.history_len) return;
        self.history_idx += 1;
        if (self.history_idx == self.history_len) {
            @memcpy(self.buf[0..self.saved_input_len], self.saved_input[0..self.saved_input_len]);
            self.len = self.saved_input_len;
            self.pos = self.saved_input_len;
        } else if (self.history[self.history_idx]) |entry| {
            self.loadEntry(entry);
        }
    }

    fn loadEntry(self: *LineEditor, entry: []const u8) void {
        const n = @min(entry.len, max_buf);
        @memcpy(self.buf[0..n], entry[0..n]);
        self.len = n;
        self.pos = n;
    }

    // --- persistent history ---

    fn resolveHistoryPath(self: *LineEditor) void {
        // Zig 0.16: `std.process.getEnvVarOwned` / `posix.getenv` are gone; read
        // through the project's published process env (`init.environ_map`,
        // published by the CLI at startup), borrowed — dup into history_path.
        const home = process_env.get("HOME") orelse return;
        self.history_path = std.fmt.allocPrint(self.allocator, "{s}/.cljw_history", .{home}) catch null;
    }

    fn loadHistory(self: *LineEditor) void {
        const path = self.history_path orelse return;
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return;
        defer file.close(self.io);

        var read_buf: [4096]u8 = undefined;
        var line_buf: [max_buf]u8 = undefined;
        var line_len: usize = 0;
        var fr = file.readerStreaming(self.io, &read_buf);
        while (true) {
            const byte = fr.interface.takeByte() catch break;
            if (byte == '\n') {
                if (line_len > 0) {
                    self.pushHistoryRaw(line_buf[0..line_len]);
                    line_len = 0;
                }
            } else if (line_len < line_buf.len) {
                line_buf[line_len] = byte;
                line_len += 1;
            }
        }
        if (line_len > 0) self.pushHistoryRaw(line_buf[0..line_len]);
        self.history_idx = self.history_len;
    }

    fn pushHistoryRaw(self: *LineEditor, line: []const u8) void {
        const entry = self.allocator.dupe(u8, line) catch return;
        if (self.history_len < max_history) {
            self.history[self.history_len] = entry;
            self.history_len += 1;
        } else {
            if (self.history[0]) |oldest| self.allocator.free(oldest);
            for (0..max_history - 1) |i| self.history[i] = self.history[i + 1];
            self.history[max_history - 1] = entry;
        }
    }

    /// Flush the whole in-memory ring to the history file at session end.
    /// Truncate-and-rewrite (not append) because this 0.16 File surface
    /// exposes no append-mode or seek; the ring is already bounded to
    /// `max_history`, so rewriting it once at exit is cheap and keeps the
    /// file capped without an external prune step.
    fn saveHistory(self: *LineEditor) void {
        const path = self.history_path orelse return;
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true }) catch return;
        defer file.close(self.io);
        var wbuf: [4096]u8 = undefined;
        var fw = file.writer(self.io, &wbuf);
        for (self.history[0..self.history_len]) |entry| {
            if (entry) |line| {
                fw.interface.writeAll(line) catch return;
                fw.interface.writeByte('\n') catch return;
            }
        }
        fw.interface.flush() catch {};
    }

    // --- tab completion ---

    /// Complete the symbol under the cursor from the live Env, via the
    /// shared `runtime/introspect.zig` enumeration (ADR-0170 — the
    /// same candidates the nREPL `completions` op serves). Handles an
    /// unqualified prefix and a `ns/var` qualified one; the candidate
    /// type annotation is ignored here (a raw terminal lists names).
    fn handleTab(self: *LineEditor) void {
        const env = self.env orelse return;

        var start = self.pos;
        while (start > 0 and (isSymbolChar(self.buf[start - 1]) or self.buf[start - 1] == ':')) start -= 1;
        const prefix = self.buf[start..self.pos];
        if (prefix.len == 0) return;

        var candidates: [64][]const u8 = undefined;
        var count: usize = 0;
        var sink = TabSink{ .candidates = &candidates, .count = &count };

        if (std.mem.findScalar(u8, prefix, '/')) |slash| {
            const var_prefix = prefix[slash + 1 ..];
            if (introspect.resolveQualifier(env, env.current_ns, prefix[0..slash])) |target| {
                introspect.forEachNsVar(target, var_prefix, &sink, TabSink.cb);
            }
            self.showCompletions(&candidates, count, var_prefix);
        } else {
            introspect.forEachUnqualified(env, env.current_ns, prefix, &sink, TabSink.cb);
            self.showCompletions(&candidates, count, prefix);
        }
    }

    /// Fixed-slot, allocation-free candidate sink (dedup is the
    /// consumer's concern per introspect.zig's contract).
    const TabSink = struct {
        candidates: *[64][]const u8,
        count: *usize,

        fn cb(self: *TabSink, c: introspect.Candidate) bool {
            if (self.count.* >= self.candidates.len) return false;
            for (self.candidates[0..self.count.*]) |e| {
                if (std.mem.eql(u8, e, c.name)) return true;
            }
            self.candidates[self.count.*] = c.name;
            self.count.* += 1;
            return true;
        }
    };

    fn showCompletions(self: *LineEditor, candidates: *[64][]const u8, count: usize, prefix: []const u8) void {
        if (count == 0) return;
        if (count == 1) {
            const completion = candidates[0];
            if (completion.len > prefix.len) {
                for (completion[prefix.len..]) |c| self.insertChar(c);
            }
            self.insertChar(' ');
            return;
        }
        // Multiple: extend to the longest common prefix, else list them.
        var common = candidates[0].len;
        for (candidates[1..count]) |cand| {
            var j: usize = 0;
            while (j < common and j < cand.len and cand[j] == candidates[0][j]) j += 1;
            common = j;
        }
        if (common > prefix.len) {
            for (candidates[0][prefix.len..common]) |c| self.insertChar(c);
        } else {
            self.disableRawMode();
            self.writeStr("\r\n");
            for (candidates[0..count]) |cand| {
                self.writeStr(cand);
                self.writeStr("  ");
            }
            self.writeStr("\r\n");
            self.prev_cursor_row = 0;
            self.enableRawMode();
        }
    }

    // --- helpers ---

    fn isWordChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }

    fn isSymbolChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or switch (c) {
            '_', '-', '.', '/', '!', '?', '*', '+', '>', '<', '=' => true,
            else => false,
        };
    }
};

/// Count the net delimiter nesting depth, ignoring `"strings"` and
/// `; comments`. Returns > 0 when more openers than closers (the input
/// is an incomplete form and the editor should keep reading), 0 when
/// balanced, < 0 when over-closed.
pub fn countDelimiterDepth(source: []const u8) i32 {
    var d: i32 = 0;
    var in_string = false;
    var in_comment = false;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (in_comment) {
            if (c == '\n') in_comment = false;
            continue;
        }
        if (in_string) {
            if (c == '\\') {
                i += 1; // skip the escaped char
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            ';' => in_comment = true,
            '"' => in_string = true,
            '(', '[', '{' => d += 1,
            ')', ']', '}' => d -= 1,
            else => {},
        }
    }
    return d;
}

// --- tests ---

const testing = std.testing;

test "countDelimiterDepth balanced" {
    try testing.expectEqual(@as(i32, 0), countDelimiterDepth("(+ 1 2)"));
    try testing.expectEqual(@as(i32, 0), countDelimiterDepth("[1 2 3]"));
    try testing.expectEqual(@as(i32, 0), countDelimiterDepth("{:a 1}"));
}

test "countDelimiterDepth unbalanced" {
    try testing.expectEqual(@as(i32, 1), countDelimiterDepth("(defn foo"));
    try testing.expectEqual(@as(i32, 2), countDelimiterDepth("(defn foo ["));
    try testing.expectEqual(@as(i32, -1), countDelimiterDepth(")"));
}

test "countDelimiterDepth ignores strings" {
    try testing.expectEqual(@as(i32, 0), countDelimiterDepth("\"(\""));
    try testing.expectEqual(@as(i32, 0), countDelimiterDepth("(\"hello\")"));
    try testing.expectEqual(@as(i32, 1), countDelimiterDepth("(\"hello\")\"\"("));
}

test "countDelimiterDepth ignores comments" {
    try testing.expectEqual(@as(i32, 0), countDelimiterDepth("; ("));
    try testing.expectEqual(@as(i32, 1), countDelimiterDepth("(\n; )"));
}

test "isWordChar" {
    try testing.expect(LineEditor.isWordChar('a'));
    try testing.expect(LineEditor.isWordChar('Z'));
    try testing.expect(LineEditor.isWordChar('0'));
    try testing.expect(LineEditor.isWordChar('-'));
    try testing.expect(LineEditor.isWordChar('_'));
    try testing.expect(!LineEditor.isWordChar(' '));
    try testing.expect(!LineEditor.isWordChar('('));
}

test "isSymbolChar" {
    try testing.expect(LineEditor.isSymbolChar('a'));
    try testing.expect(LineEditor.isSymbolChar('!'));
    try testing.expect(LineEditor.isSymbolChar('?'));
    try testing.expect(LineEditor.isSymbolChar('/'));
    try testing.expect(LineEditor.isSymbolChar('*'));
    try testing.expect(!LineEditor.isSymbolChar(' '));
    try testing.expect(!LineEditor.isSymbolChar('('));
}
