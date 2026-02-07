// Line editor for the interactive REPL.
//
// Pure Zig implementation (no external dependencies).
// Features: emacs keybindings, history, multi-line, tab completion,
// paren matching flash.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Env = @import("../common/env.zig").Env;
const Namespace = @import("../common/namespace.zig").Namespace;
const VarMap = @import("../common/namespace.zig").VarMap;
const posix = std.posix;

// termios cc[] indices — platform-dependent
const VMIN: usize = switch (builtin.os.tag) {
    .linux => 6,
    .macos, .ios, .tvos, .watchos, .visionos => 16,
    else => 16,
};
const VTIME: usize = switch (builtin.os.tag) {
    .linux => 5,
    .macos, .ios, .tvos, .watchos, .visionos => 17,
    else => 17,
};

// =====================================================================
// Key types
// =====================================================================

pub const Key = union(enum) {
    char: u8,
    ctrl: u8, // C-a = 'a', C-e = 'e', etc.
    alt: u8, // Alt-f, Alt-b, Alt-d, etc.
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

// =====================================================================
// LineEditor
// =====================================================================

pub const LineEditor = struct {
    // Terminal state
    orig_termios: posix.termios,
    tty: std.fs.File,
    raw_mode: bool,

    // Edit buffer (single line or multi-line joined by \n)
    buf: [max_buf]u8,
    len: usize,
    pos: usize, // cursor byte position in buf

    // Multi-line state
    depth: i32, // bracket depth (> 0 = continuation)

    // Yank buffer (C-k / C-w / Alt-d fill, C-y pastes)
    yank_buf: [max_buf]u8,
    yank_len: usize,

    // History
    history: [max_history]?[]const u8,
    history_len: usize,
    history_idx: usize, // current browsing index (history_len = current input)
    saved_input: [max_buf]u8, // saved current input when browsing history
    saved_input_len: usize,

    // Persistent history file
    history_path: ?[]const u8,

    // Tab completion
    env: ?*Env,

    // Allocator for history string duplication
    allocator: Allocator,

    // Prompt
    prompt: []const u8,
    cont_prompt: []const u8,

    // Rendering state: number of terminal lines from previous refresh
    prev_rendered_lines: usize,

    const max_buf = 65536;
    const max_history = 1000;

    pub fn init(allocator: Allocator, env: ?*Env) LineEditor {
        var self = LineEditor{
            .orig_termios = undefined,
            .tty = .{ .handle = posix.STDIN_FILENO },
            .raw_mode = false,
            .buf = undefined,
            .len = 0,
            .pos = 0,
            .depth = 0,
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
            .cont_prompt = "     | ",
            .prev_rendered_lines = 0,
        };
        self.resolveHistoryPath();
        self.loadHistory();
        return self;
    }

    pub fn deinit(self: *LineEditor) void {
        self.disableRawMode();
        // Free history strings
        for (&self.history) |*entry| {
            if (entry.*) |s| {
                self.allocator.free(s);
                entry.* = null;
            }
        }
    }

    // =================================================================
    // Public API: read one complete expression
    // =================================================================

    /// Read a complete expression from the terminal.
    /// Returns the expression string (slice into internal buffer), or null on EOF.
    pub fn readInput(self: *LineEditor) ?[]const u8 {
        self.len = 0;
        self.pos = 0;
        self.depth = 0;
        self.prev_rendered_lines = 0;

        while (true) {
            self.enableRawMode();
            self.refresh();

            const key = self.readKey();

            switch (key) {
                .eof => {
                    self.disableRawMode();
                    if (self.len == 0) return null;
                    // Non-empty buffer with EOF: treat as enter
                    break;
                },
                .enter => {
                    self.depth = countDelimiterDepth(self.buf[0..self.len]);
                    if (self.depth > 0) {
                        // Continuation: insert newline
                        self.insertChar('\n');
                        continue;
                    }
                    // Complete expression
                    self.disableRawMode();
                    self.writeStr("\r\n");
                    break;
                },
                .alt_enter => {
                    // Force newline regardless of bracket depth
                    self.insertChar('\n');
                    continue;
                },
                .tab => {
                    self.handleTab();
                    continue;
                },
                .backspace => {
                    self.deleteBack();
                    continue;
                },
                .delete => {
                    self.deleteForward();
                    continue;
                },
                .left => {
                    self.moveLeft();
                    continue;
                },
                .right => {
                    self.moveRight();
                    continue;
                },
                .up => {
                    self.historyPrev();
                    continue;
                },
                .down => {
                    self.historyNext();
                    continue;
                },
                .home => {
                    self.moveHome();
                    continue;
                },
                .end => {
                    self.moveEnd();
                    continue;
                },
                .ctrl => |c| {
                    switch (c) {
                        'a' => self.moveHome(),
                        'e' => self.moveEnd(),
                        'f' => self.moveRight(),
                        'b' => self.moveLeft(),
                        'k' => self.killToEnd(),
                        'u' => self.killToStart(),
                        'w' => self.killWordBack(),
                        'y' => self.yank(),
                        'o' => self.insertChar('\n'), // force newline
                        'd' => {
                            if (self.len == 0) {
                                // Empty line: EOF
                                self.disableRawMode();
                                return null;
                            }
                            self.deleteForward();
                        },
                        'p' => self.historyPrev(),
                        'n' => self.historyNext(),
                        'c' => {
                            // Clear line, print ^C, new prompt
                            self.disableRawMode();
                            self.writeStr("^C\r\n");
                            self.len = 0;
                            self.pos = 0;
                            self.depth = 0;
                            self.prev_rendered_lines = 0;
                            continue;
                        },
                        'l' => {
                            // Clear screen
                            self.writeStr("\x1b[2J\x1b[H");
                            self.prev_rendered_lines = 0;
                        },
                        else => {},
                    }
                    continue;
                },
                .alt => |c| {
                    switch (c) {
                        'f' => self.moveWordForward(),
                        'b' => self.moveWordBack(),
                        'd' => self.killWordForward(),
                        else => {},
                    }
                    continue;
                },
                .char => |c| {
                    self.insertChar(c);
                    // Paren matching flash
                    if (c == ')' or c == ']' or c == '}') {
                        self.flashMatchingParen();
                    }
                    continue;
                },
                .unknown => continue,
            }

            // Fell through from enter/eof with complete expression
            break;
        }

        if (self.len == 0) return null;

        const input = self.buf[0..self.len];
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len > 0) {
            self.addHistory(trimmed);
        }
        return input;
    }

    // =================================================================
    // Terminal raw mode
    // =================================================================

    fn enableRawMode(self: *LineEditor) void {
        if (self.raw_mode) return;
        self.orig_termios = posix.tcgetattr(self.tty.handle) catch return;
        var raw = self.orig_termios;
        // Input: no break, no CR->NL, no parity, no strip, no flow ctrl
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        // Output: disable post-processing
        raw.oflag.OPOST = false;
        // Local: no echo, no canonical, no extended, no signal
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        // Control chars: read returns after 1 byte, no timeout
        raw.cc[VMIN] = 1; // read returns after 1 byte
        raw.cc[VTIME] = 0; // no timeout
        posix.tcsetattr(self.tty.handle, .FLUSH, raw) catch return;
        self.raw_mode = true;
    }

    fn disableRawMode(self: *LineEditor) void {
        if (!self.raw_mode) return;
        posix.tcsetattr(self.tty.handle, .FLUSH, self.orig_termios) catch {};
        self.raw_mode = false;
    }

    // =================================================================
    // Key reading
    // =================================================================

    fn readByte(self: *LineEditor) ?u8 {
        var byte: [1]u8 = undefined;
        const n = self.tty.read(&byte) catch return null;
        if (n == 0) return null;
        return byte[0];
    }

    /// Read a byte with timeout (for ESC sequence disambiguation).
    /// Uses VMIN=0,VTIME=1 (100ms timeout).
    fn readByteTimeout(self: *LineEditor) ?u8 {
        // Save current cc values and set timeout mode
        var raw = posix.tcgetattr(self.tty.handle) catch return null;
        const saved_vmin = raw.cc[VMIN];
        const saved_vtime = raw.cc[VTIME];
        raw.cc[VMIN] = 0; // VMIN: return immediately if no data
        raw.cc[VTIME] = 1; // VTIME: 100ms timeout
        posix.tcsetattr(self.tty.handle, .NOW, raw) catch return null;
        defer {
            raw.cc[VMIN] = saved_vmin;
            raw.cc[VTIME] = saved_vtime;
            posix.tcsetattr(self.tty.handle, .NOW, raw) catch {};
        }
        var byte: [1]u8 = undefined;
        const n = self.tty.read(&byte) catch return null;
        if (n == 0) return null;
        return byte[0];
    }

    fn readKey(self: *LineEditor) Key {
        const c = self.readByte() orelse return .eof;

        switch (c) {
            '\r', '\n' => return .enter,
            '\t' => return .tab,
            127 => return .backspace,
            1...8, 11...12, 14...26 => |ctrl| {
                // Ctrl-A through Ctrl-Z (excluding \t=9, \n=10, \r=13)
                return .{ .ctrl = ctrl + 'a' - 1 };
            },
            27 => { // ESC
                const next = self.readByteTimeout() orelse return .unknown;
                switch (next) {
                    '[' => return self.readCsiSequence(),
                    'O' => return self.readSsSequence(),
                    '\r', '\n' => return .alt_enter, // ESC + CR/LF = Alt-Enter
                    'a'...'z' => return .{ .alt = next },
                    else => {
                        if (next >= 'A' and next <= 'Z') {
                            return .{ .alt = next + 32 }; // normalize to lowercase
                        }
                        return .unknown;
                    },
                }
            },
            ' '...126 => return .{ .char = c },
            128...255 => {
                // UTF-8 multi-byte: pass through first byte as char
                // (we only handle ASCII editing, non-ASCII bytes are inserted as-is)
                return .{ .char = c };
            },
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
                // Extended sequence: ESC [ <number> ; ... ~ or u
                var buf_idx: usize = 0;
                var params: [4]u32 = .{ 0, 0, 0, 0 };
                params[0] = first - '0';
                var param_count: usize = 1;
                while (buf_idx < 16) : (buf_idx += 1) {
                    const b = self.readByteTimeout() orelse return .unknown;
                    switch (b) {
                        '0'...'9' => {
                            params[param_count - 1] = params[param_count - 1] * 10 + (b - '0');
                        },
                        ';' => {
                            if (param_count < params.len) param_count += 1;
                        },
                        '~' => {
                            // ESC [ 3 ~ = Delete
                            if (params[0] == 3) return .delete;
                            if (params[0] == 1) return .home;
                            if (params[0] == 4) return .end;
                            return .unknown;
                        },
                        'u' => {
                            // CSI u (kitty keyboard protocol)
                            // ESC [ 13 ; 2 u = Shift-Enter
                            if (params[0] == 13 and param_count >= 2 and params[1] == 2) {
                                return .alt_enter;
                            }
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
        switch (c) {
            'A' => return .up,
            'B' => return .down,
            'C' => return .right,
            'D' => return .left,
            'H' => return .home,
            'F' => return .end,
            else => return .unknown,
        }
    }

    // =================================================================
    // Edit operations
    // =================================================================

    fn insertChar(self: *LineEditor, c: u8) void {
        if (self.len >= max_buf - 1) return;
        if (self.pos < self.len) {
            // Shift right
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
        // Move to start of current line (after last \n before cursor, or 0)
        if (self.pos == 0) return;
        var i = self.pos - 1;
        while (i > 0 and self.buf[i] != '\n') : (i -= 1) {}
        if (self.buf[i] == '\n') {
            self.pos = i + 1;
        } else {
            self.pos = 0;
        }
    }

    fn moveEnd(self: *LineEditor) void {
        // Move to end of current line (next \n or end of buffer)
        while (self.pos < self.len and self.buf[self.pos] != '\n') {
            self.pos += 1;
        }
    }

    fn moveWordForward(self: *LineEditor) void {
        // Skip non-word chars, then skip word chars
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
        // Kill from cursor to end of current line
        var end = self.pos;
        while (end < self.len and self.buf[end] != '\n') end += 1;
        const killed_len = end - self.pos;
        if (killed_len > 0) {
            @memcpy(self.yank_buf[0..killed_len], self.buf[self.pos..end]);
            self.yank_len = killed_len;
            if (end < self.len) {
                std.mem.copyForwards(u8, self.buf[self.pos .. self.len - killed_len], self.buf[end..self.len]);
            }
            self.len -= killed_len;
        }
    }

    fn killToStart(self: *LineEditor) void {
        // Kill from start of current line to cursor
        var start = self.pos;
        if (start > 0) {
            start -= 1;
            while (start > 0 and self.buf[start - 1] != '\n') start -= 1;
        } else {
            return;
        }
        const killed_len = self.pos - start;
        if (killed_len > 0) {
            @memcpy(self.yank_buf[0..killed_len], self.buf[start..self.pos]);
            self.yank_len = killed_len;
            std.mem.copyForwards(u8, self.buf[start .. self.len - killed_len], self.buf[self.pos..self.len]);
            self.len -= killed_len;
            self.pos = start;
        }
    }

    fn killWordBack(self: *LineEditor) void {
        if (self.pos == 0) return;
        const orig_pos = self.pos;
        // Move back over non-word, then word chars
        while (self.pos > 0 and !isWordChar(self.buf[self.pos - 1])) self.pos -= 1;
        while (self.pos > 0 and isWordChar(self.buf[self.pos - 1])) self.pos -= 1;
        const killed_len = orig_pos - self.pos;
        @memcpy(self.yank_buf[0..killed_len], self.buf[self.pos..orig_pos]);
        self.yank_len = killed_len;
        std.mem.copyForwards(u8, self.buf[self.pos .. self.len - killed_len], self.buf[orig_pos..self.len]);
        self.len -= killed_len;
    }

    fn killWordForward(self: *LineEditor) void {
        if (self.pos >= self.len) return;
        const orig_pos = self.pos;
        // Skip non-word, then word chars
        while (self.pos < self.len and !isWordChar(self.buf[self.pos])) self.pos += 1;
        while (self.pos < self.len and isWordChar(self.buf[self.pos])) self.pos += 1;
        const killed_len = self.pos - orig_pos;
        @memcpy(self.yank_buf[0..killed_len], self.buf[orig_pos..self.pos]);
        self.yank_len = killed_len;
        if (self.pos < self.len) {
            std.mem.copyForwards(u8, self.buf[orig_pos .. self.len - killed_len], self.buf[self.pos..self.len]);
        }
        self.len -= killed_len;
        self.pos = orig_pos;
    }

    fn yank(self: *LineEditor) void {
        if (self.yank_len == 0) return;
        if (self.len + self.yank_len >= max_buf) return;
        // Make room
        if (self.pos < self.len) {
            std.mem.copyBackwards(u8, self.buf[self.pos + self.yank_len .. self.len + self.yank_len], self.buf[self.pos..self.len]);
        }
        @memcpy(self.buf[self.pos .. self.pos + self.yank_len], self.yank_buf[0..self.yank_len]);
        self.pos += self.yank_len;
        self.len += self.yank_len;
    }

    // =================================================================
    // Rendering
    // =================================================================

    fn refresh(self: *LineEditor) void {
        var out_buf: [8192]u8 = undefined;
        var stream = std.io.fixedBufferStream(&out_buf);
        const w = stream.writer();

        // Move cursor up to the first line of previous render, then clear
        if (self.prev_rendered_lines > 1) {
            w.print("\x1b[{d}A", .{self.prev_rendered_lines - 1}) catch return;
        }
        w.writeAll("\r\x1b[J") catch return;

        // Split buffer into lines
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
                // Write this line with prompt
                const pr = if (line_idx == 0) self.prompt else self.cont_prompt;
                w.writeAll(pr) catch return;
                w.writeAll(content[line_start..i]) catch return;
                w.writeAll("\r\n") catch return;
                line_start = i + 1;
                line_idx += 1;
            }
        }

        // Last line (or only line)
        if (self.pos >= line_start and self.pos <= self.len) {
            if (self.pos == self.len) {
                cursor_row = line_idx;
                cursor_col = self.len - line_start;
            }
        }
        const pr = if (line_idx == 0) self.prompt else self.cont_prompt;
        w.writeAll(pr) catch return;
        w.writeAll(content[line_start..]) catch return;

        // Track rendered line count for next refresh
        self.prev_rendered_lines = line_idx + 1;

        // Move cursor to correct position:
        // We're at end of last line. Move up (line_idx - cursor_row) rows,
        // then to correct column.
        const lines_below = line_idx - cursor_row;
        if (lines_below > 0) {
            w.print("\x1b[{d}A", .{lines_below}) catch return;
        }
        const prompt_for_cursor = if (cursor_row == 0) self.prompt else self.cont_prompt;
        w.print("\r\x1b[{d}C", .{prompt_for_cursor.len + cursor_col}) catch return;

        const stdout: std.fs.File = .{ .handle = posix.STDOUT_FILENO };
        _ = stdout.write(stream.getWritten()) catch {};
    }

    fn writeStr(self: *LineEditor, s: []const u8) void {
        _ = self;
        const stdout: std.fs.File = .{ .handle = posix.STDOUT_FILENO };
        _ = stdout.write(s) catch {};
    }

    // =================================================================
    // History
    // =================================================================

    fn addHistory(self: *LineEditor, line: []const u8) void {
        // Skip if duplicate of last entry
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
            // Rotate: free oldest, shift down, append
            if (self.history[0]) |oldest| {
                self.allocator.free(oldest);
            }
            for (0..max_history - 1) |i| {
                self.history[i] = self.history[i + 1];
            }
            self.history[max_history - 1] = duped;
        }
        self.history_idx = self.history_len;

        // Append to persistent file
        self.appendHistoryFile(line);
    }

    fn historyPrev(self: *LineEditor) void {
        if (self.history_len == 0 or self.history_idx == 0) return;

        // Save current input if we're at the bottom
        if (self.history_idx == self.history_len) {
            @memcpy(self.saved_input[0..self.len], self.buf[0..self.len]);
            self.saved_input_len = self.len;
        }

        self.history_idx -= 1;
        if (self.history[self.history_idx]) |entry| {
            const entry_len = @min(entry.len, max_buf);
            @memcpy(self.buf[0..entry_len], entry[0..entry_len]);
            self.len = entry_len;
            self.pos = entry_len;
        }
    }

    fn historyNext(self: *LineEditor) void {
        if (self.history_idx >= self.history_len) return;

        self.history_idx += 1;
        if (self.history_idx == self.history_len) {
            // Restore saved input
            @memcpy(self.buf[0..self.saved_input_len], self.saved_input[0..self.saved_input_len]);
            self.len = self.saved_input_len;
            self.pos = self.saved_input_len;
        } else if (self.history[self.history_idx]) |entry| {
            const entry_len = @min(entry.len, max_buf);
            @memcpy(self.buf[0..entry_len], entry[0..entry_len]);
            self.len = entry_len;
            self.pos = entry_len;
        }
    }

    // =================================================================
    // Persistent history
    // =================================================================

    fn resolveHistoryPath(self: *LineEditor) void {
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return;
        defer self.allocator.free(home);
        const path = std.fmt.allocPrint(self.allocator, "{s}/.cljw_history", .{home}) catch return;
        self.history_path = path;
    }

    fn loadHistory(self: *LineEditor) void {
        const path = self.history_path orelse return;
        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();

        var read_buf: [4096]u8 = undefined;
        var line_buf: [max_buf]u8 = undefined;
        var line_len: usize = 0;

        while (true) {
            const n = file.read(&read_buf) catch break;
            if (n == 0) break;
            for (read_buf[0..n]) |byte| {
                if (byte == '\n') {
                    if (line_len > 0) {
                        const entry = self.allocator.dupe(u8, line_buf[0..line_len]) catch continue;
                        if (self.history_len < max_history) {
                            self.history[self.history_len] = entry;
                            self.history_len += 1;
                        } else {
                            if (self.history[0]) |oldest| self.allocator.free(oldest);
                            for (0..max_history - 1) |i| {
                                self.history[i] = self.history[i + 1];
                            }
                            self.history[max_history - 1] = entry;
                        }
                        line_len = 0;
                    }
                } else {
                    if (line_len < line_buf.len) {
                        line_buf[line_len] = byte;
                        line_len += 1;
                    }
                }
            }
        }
        self.history_idx = self.history_len;
    }

    fn appendHistoryFile(self: *LineEditor, line: []const u8) void {
        const path = self.history_path orelse return;
        const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;
        _ = file.write(line) catch return;
        _ = file.write("\n") catch return;
    }

    // =================================================================
    // Tab completion
    // =================================================================

    fn handleTab(self: *LineEditor) void {
        const env_ptr = self.env orelse return;

        // Extract prefix: word chars before cursor
        var start = self.pos;
        while (start > 0 and isSymbolChar(self.buf[start - 1])) start -= 1;
        const prefix = self.buf[start..self.pos];
        if (prefix.len == 0) return;

        // Collect completions
        var candidates_buf: [64][]const u8 = undefined;
        var candidate_count: usize = 0;

        // Current namespace
        if (env_ptr.current_ns) |ns| {
            collectSymbolCompletions(&candidates_buf, &candidate_count, &ns.mappings, prefix);
            collectSymbolCompletions(&candidates_buf, &candidate_count, &ns.refers, prefix);
        }
        // clojure.core
        if (env_ptr.findNamespace("clojure.core")) |core_ns| {
            collectSymbolCompletions(&candidates_buf, &candidate_count, &core_ns.mappings, prefix);
        }

        if (candidate_count == 0) return;

        if (candidate_count == 1) {
            // Single match: complete it
            const completion = candidates_buf[0];
            const suffix = completion[prefix.len..];
            for (suffix) |c| self.insertChar(c);
            self.insertChar(' ');
        } else {
            // Multiple matches: find common prefix and show candidates
            var common_len = candidates_buf[0].len;
            for (candidates_buf[1..candidate_count]) |cand| {
                var j: usize = 0;
                while (j < common_len and j < cand.len and cand[j] == candidates_buf[0][j]) j += 1;
                common_len = j;
            }
            // Insert common prefix beyond what's already typed
            if (common_len > prefix.len) {
                const suffix = candidates_buf[0][prefix.len..common_len];
                for (suffix) |c| self.insertChar(c);
            } else {
                // Show candidates
                self.disableRawMode();
                self.writeStr("\r\n");
                for (candidates_buf[0..candidate_count]) |cand| {
                    self.writeStr(cand);
                    self.writeStr("  ");
                }
                self.writeStr("\r\n");
                self.prev_rendered_lines = 0;
                self.enableRawMode();
            }
        }
    }

    fn collectSymbolCompletions(
        candidates: *[64][]const u8,
        count: *usize,
        var_map: *const VarMap,
        prefix: []const u8,
    ) void {
        var iter = var_map.iterator();
        while (iter.next()) |entry| {
            if (count.* >= candidates.len) return;
            const name = entry.key_ptr.*;
            if (std.mem.startsWith(u8, name, prefix)) {
                // Check for duplicates
                var dup = false;
                for (candidates[0..count.*]) |existing| {
                    if (std.mem.eql(u8, existing, name)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    candidates[count.*] = name;
                    count.* += 1;
                }
            }
        }
    }

    // =================================================================
    // Paren matching
    // =================================================================

    fn flashMatchingParen(self: *LineEditor) void {
        if (self.pos == 0) return;
        const close = self.buf[self.pos - 1];
        const open: u8 = switch (close) {
            ')' => '(',
            ']' => '[',
            '}' => '{',
            else => return,
        };

        // Scan backwards to find matching opener
        var depth: i32 = 0;
        var in_string = false;
        var i: usize = self.pos - 1;
        while (true) {
            const c = self.buf[i];
            if (in_string) {
                if (c == '"' and (i == 0 or self.buf[i - 1] != '\\')) {
                    in_string = false;
                }
            } else {
                if (c == '"') {
                    in_string = true;
                } else if (c == close) {
                    depth += 1;
                } else if (c == open) {
                    depth -= 1;
                    if (depth == 0) {
                        // Found match! Flash it.
                        const saved_pos = self.pos;
                        self.pos = i;
                        self.refresh();
                        // Brief pause (150ms)
                        std.posix.nanosleep(0, 150_000_000);
                        self.pos = saved_pos;
                        return;
                    }
                }
            }
            if (i == 0) break;
            i -= 1;
        }
    }

    // =================================================================
    // Helpers
    // =================================================================

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

// =====================================================================
// Delimiter depth counter (shared with main.zig)
// =====================================================================

/// Count nesting depth of delimiters in source.
/// Returns > 0 if more openers than closers, 0 if balanced, < 0 if over-closed.
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
                i += 1; // skip escaped char
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

// =====================================================================
// Tests
// =====================================================================

test "countDelimiterDepth balanced" {
    try std.testing.expectEqual(@as(i32, 0), countDelimiterDepth("(+ 1 2)"));
    try std.testing.expectEqual(@as(i32, 0), countDelimiterDepth("[1 2 3]"));
    try std.testing.expectEqual(@as(i32, 0), countDelimiterDepth("{:a 1}"));
}

test "countDelimiterDepth unbalanced" {
    try std.testing.expectEqual(@as(i32, 1), countDelimiterDepth("(defn foo"));
    try std.testing.expectEqual(@as(i32, 2), countDelimiterDepth("(defn foo ["));
    try std.testing.expectEqual(@as(i32, -1), countDelimiterDepth(")"));
}

test "countDelimiterDepth ignores strings" {
    try std.testing.expectEqual(@as(i32, 0), countDelimiterDepth("\"(\""));
    try std.testing.expectEqual(@as(i32, 0), countDelimiterDepth("(\"hello\")\""));
    // After string ends, ( is counted as delimiter
    try std.testing.expectEqual(@as(i32, 1), countDelimiterDepth("(\"hello\")\"\"("));
}

test "countDelimiterDepth ignores comments" {
    try std.testing.expectEqual(@as(i32, 0), countDelimiterDepth("; ("));
    try std.testing.expectEqual(@as(i32, 1), countDelimiterDepth("(\n; )"));
}

test "isWordChar" {
    try std.testing.expect(LineEditor.isWordChar('a'));
    try std.testing.expect(LineEditor.isWordChar('Z'));
    try std.testing.expect(LineEditor.isWordChar('0'));
    try std.testing.expect(LineEditor.isWordChar('-'));
    try std.testing.expect(LineEditor.isWordChar('_'));
    try std.testing.expect(!LineEditor.isWordChar(' '));
    try std.testing.expect(!LineEditor.isWordChar('('));
}

test "isSymbolChar" {
    try std.testing.expect(LineEditor.isSymbolChar('a'));
    try std.testing.expect(LineEditor.isSymbolChar('!'));
    try std.testing.expect(LineEditor.isSymbolChar('?'));
    try std.testing.expect(LineEditor.isSymbolChar('/'));
    try std.testing.expect(LineEditor.isSymbolChar('*'));
    try std.testing.expect(!LineEditor.isSymbolChar(' '));
    try std.testing.expect(!LineEditor.isSymbolChar('('));
}
