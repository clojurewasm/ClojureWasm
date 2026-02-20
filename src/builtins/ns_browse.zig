// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! clojure.java.browse — Open URLs in a web browser.
//!
//! Replaces src/clj/clojure/java/browse.clj (54 lines).
//! Provides browse-url which uses platform-native commands to open URLs.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Value = @import("../runtime/value.zig").Value;
const BuiltinDef = @import("../runtime/var.zig").BuiltinDef;
const err = @import("../runtime/error.zig");

/// (browse-url url) — open url in a browser.
/// Uses /usr/bin/open on macOS, xdg-open on Linux.
pub fn browseUrlFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "browse-url requires exactly 1 argument", .{});

    const url_str = switch (args[0].tag()) {
        .string => args[0].asString(),
        else => return err.setErrorFmt(.eval, .type_error, .{}, "browse-url: argument must be a string", .{}),
    };

    const open_cmd = openCommand();
    if (open_cmd) |cmd| {
        var child = std.process.Child.init(&.{ cmd, url_str }, allocator);
        child.spawn() catch return args[0]; // silently fail if spawn fails
        _ = child.wait() catch {};
        return args[0];
    }

    // No browser command found
    return args[0];
}

/// Return the platform-specific "open URL" command, or null if unknown.
fn openCommand() ?[]const u8 {
    if (comptime builtin.os.tag == .macos) return "/usr/bin/open";
    if (comptime builtin.os.tag == .linux) return "xdg-open";
    return null;
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "browse-url",
        .func = browseUrlFn,
        .doc = "Open url in a browser",
        .arglists = "([url])",
        .added = "1.2",
    },
};
