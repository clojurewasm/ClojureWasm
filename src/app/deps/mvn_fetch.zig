// SPDX-License-Identifier: EPL-2.0
//! Resolve Maven jars into a source classpath on POSIX hosts.
const std = @import("std");
const env = @import("../../runtime/process_env.zig");
const file_io = @import("../../runtime/file_io.zig");
const errors = @import("../../runtime/error/catalog.zig");

fn fail(lib: []const u8, detail: []const u8) errors.ClojureWasmError {
    return errors.raise(.lib_load_failed, .{}, .{ .ns = lib, .detail = detail });
}
fn run(io: std.Io, a: std.mem.Allocator, argv: []const []const u8) bool {
    const res = std.process.run(a, io, .{ .argv = argv }) catch return false;
    return switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
}
fn tag(xml: []const u8, name: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{name}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{name}) catch return null;
    const start = std.mem.indexOf(u8, xml, open) orelse return null;
    const from = start + open.len;
    const end = std.mem.indexOfPos(u8, xml, from, close) orelse return null;
    return std.mem.trim(u8, xml[from..end], " \r\n\t");
}
fn valid(s: []const u8) bool {
    if (s.len == 0 or std.mem.indexOf(u8, s, "..") != null) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') {
        return false;
    };
    return true;
}
fn resolvePomProperty(xml: []const u8, property: []const u8, version: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, property, "project.version") or std.mem.eql(u8, property, "version")) return version;
    const properties = tag(xml, "properties") orelse return null;
    return tag(properties, property);
}
fn checksumMatches(artifact: []const u8, checksum: []const u8) bool {
    if (checksum.len < 40) return false;
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(artifact, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    return std.ascii.eqlIgnoreCase(actual[0..], checksum[0..40]) and
        (checksum.len == 40 or std.ascii.isWhitespace(checksum[40]) or checksum[40] == '*');
}
fn fetch(io: std.Io, a: std.mem.Allocator, lib: []const u8, rel: []const u8, ext: []const u8, dest: []const u8) !bool {
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{dest});
    const checksum_tmp = try std.fmt.allocPrint(a, "{s}.sha1.tmp", .{dest});
    const repos = env.get("CLJW_MVN_REPOS") orelse "https://repo.clojars.org,https://repo.maven.apache.org/maven2";
    var hosts = std.mem.splitScalar(u8, repos, ',');
    while (hosts.next()) |base| {
        const host = std.mem.trim(u8, base, " \t\r\n");
        if (host.len == 0) continue;
        const url = try std.fmt.allocPrint(a, "{s}/{s}{s}", .{ std.mem.trimEnd(u8, host, "/"), rel, ext });
        if (!run(io, a, &.{ "curl", "-fsSL", "--connect-timeout", "5", "--max-time", "30", "-o", tmp, url })) {
            std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
            continue;
        }
        const checksum_url = try std.fmt.allocPrint(a, "{s}.sha1", .{url});
        if (!run(io, a, &.{ "curl", "-fsSL", "--connect-timeout", "5", "--max-time", "30", "-o", checksum_tmp, checksum_url })) {
            std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
            std.Io.Dir.cwd().deleteFile(io, checksum_tmp) catch {};
            return fail(lib, try std.fmt.allocPrint(a, "missing SHA-1 checksum for {s}", .{url}));
        }
        const expected = file_io.readAll(io, a, checksum_tmp) catch {
            std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
            std.Io.Dir.cwd().deleteFile(io, checksum_tmp) catch {};
            return fail(lib, try std.fmt.allocPrint(a, "unreadable SHA-1 checksum for {s}", .{url}));
        };
        std.Io.Dir.cwd().deleteFile(io, checksum_tmp) catch {};
        const artifact = file_io.readAll(io, a, tmp) catch {
            std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
            return fail(lib, try std.fmt.allocPrint(a, "unreadable artifact at {s}", .{url}));
        };
        if (!checksumMatches(artifact, expected)) {
            std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
            return fail(lib, try std.fmt.allocPrint(a, "SHA-1 checksum mismatch for {s}", .{url}));
        }
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), dest, io);
        return true;
    }
    return false;
}
/// Extract Clojure sources from a Maven jar, recursively following compile/runtime POM deps.
pub fn expand(io: std.Io, a: std.mem.Allocator, lib: []const u8, version: []const u8, cache_base: ?[]const u8, paths: *std.ArrayList([]const u8), visited: *std.StringHashMapUnmanaged(void)) !void {
    if (std.mem.eql(u8, lib, "org.clojure/clojure")) return;
    const slash = std.mem.indexOfScalar(u8, lib, '/') orelse return fail(lib, "invalid Maven coordinate");
    const group = lib[0..slash];
    const artifact = lib[slash + 1 ..];
    if (!valid(group) or !valid(artifact) or !valid(version)) return fail(lib, "invalid Maven coordinate");
    const key = try std.fmt.allocPrint(a, "{s}:{s}", .{ lib, version });
    if (visited.contains(key)) return;
    try visited.put(a, key, {});
    const home = env.get("HOME");
    const repo = env.get("M2_REPO") orelse if (home) |h| try std.fmt.allocPrint(a, "{s}/.m2/repository", .{h}) else return fail(lib, "set M2_REPO or HOME");
    const group_path = try a.dupe(u8, group);
    for (group_path) |*ch| {
        if (ch.* == '.') ch.* = '/';
    }
    const rel = try std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}-{s}", .{ group_path, artifact, version, artifact, version });
    const jar = try std.fmt.allocPrint(a, "{s}/{s}.jar", .{ repo, rel });
    const pom = try std.fmt.allocPrint(a, "{s}/{s}.pom", .{ repo, rel });
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, jar, .{})) |_| {} else |_| {
        try cwd.createDirPath(io, std.fs.path.dirname(jar).?);
        if (!try fetch(io, a, lib, rel, ".jar", jar)) return fail(lib, "jar unavailable on Clojars and Maven Central");
    }
    const base = cache_base orelse return fail(lib, "set CLJW_HOME or HOME");
    const dest = try std.fmt.allocPrint(a, "{s}/mvn/{s}/{s}/{s}", .{ base, group_path, artifact, version });
    const marker = try std.fmt.allocPrint(a, "{s}/.complete", .{dest});
    if (cwd.access(io, marker, .{})) |_| {} else |_| {
        try cwd.createDirPath(io, std.fs.path.dirname(dest).?);
        const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{dest});
        cwd.deleteTree(io, tmp) catch {};
        try cwd.createDirPath(io, tmp);
        const listing = std.process.run(a, io, .{ .argv = &.{ "unzip", "-Z1", jar } }) catch return fail(lib, "cannot list jar");
        switch (listing.term) {
            .exited => |code| if (code != 0) return fail(lib, "invalid jar archive"),
            else => return fail(lib, "cannot list jar"),
        }
        var sources = false;
        var entries = std.mem.splitScalar(u8, listing.stdout, '\n');
        while (entries.next()) |entry| {
            if (entry.len == 0 or entry[0] == '/' or std.mem.indexOf(u8, entry, "..") != null or std.mem.indexOfScalar(u8, entry, '\\') != null) continue;
            if (std.mem.endsWith(u8, entry, ".clj") or std.mem.endsWith(u8, entry, ".cljc") or std.mem.endsWith(u8, entry, ".cljw")) {
                if (!run(io, a, &.{ "unzip", "-qq", "-o", jar, entry, "-d", tmp })) return fail(lib, "cannot extract jar source");
                sources = true;
            }
        }
        if (sources) {
            const f = try cwd.createFile(io, try std.fmt.allocPrint(a, "{s}/.complete", .{tmp}), .{});
            f.close(io);
            cwd.rename(tmp, cwd, dest, io) catch |e| return fail(lib, @errorName(e));
        } else cwd.deleteTree(io, tmp) catch {};
    }
    if (cwd.access(io, marker, .{})) |_| try paths.append(a, dest) else |_| {}
    if (cwd.access(io, pom, .{})) |_| {} else |_| {
        _ = try fetch(io, a, lib, rel, ".pom", pom);
    }
    const xml = file_io.readAll(io, a, pom) catch return;
    // dependencyManagement entries are constraints, not dependencies to load.
    const management_start = std.mem.indexOf(u8, xml, "<dependencyManagement>");
    const management_end = std.mem.indexOf(u8, xml, "</dependencyManagement>");
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<dependency>")) |begin| {
        if (management_start) |start| {
            if (management_end) |end_management| {
                if (begin >= start and begin < end_management) {
                    pos = end_management + "</dependencyManagement>".len;
                    continue;
                }
            }
        }
        const end = std.mem.indexOfPos(u8, xml, begin, "</dependency>") orelse break;
        pos = end + "</dependency>".len;
        const block = xml[begin..end];
        const scope = tag(block, "scope") orelse "compile";
        if (!std.mem.eql(u8, scope, "compile") and !std.mem.eql(u8, scope, "runtime")) continue;
        if (std.mem.eql(u8, tag(block, "optional") orelse "false", "true")) continue;
        const child_group = tag(block, "groupId") orelse continue;
        const child_artifact = tag(block, "artifactId") orelse continue;
        const raw_version = tag(block, "version") orelse continue;
        const child_version = if (std.mem.startsWith(u8, raw_version, "${") and std.mem.endsWith(u8, raw_version, "}")) blk: {
            const property = raw_version[2 .. raw_version.len - 1];
            break :blk resolvePomProperty(xml, property, version) orelse continue;
        } else raw_version;
        if (std.mem.indexOfScalar(u8, child_version, '$') != null) continue;
        try expand(io, a, try std.fmt.allocPrint(a, "{s}/{s}", .{ child_group, child_artifact }), child_version, cache_base, paths, visited);
    }
}

test "Maven SHA-1 checksum validates bytes and rejects tampering" {
    const good = "a9993e364706816aba3e25717850c26c9cd0d89d";
    try std.testing.expect(checksumMatches("abc", good ++ "  abc.jar\n"));
    try std.testing.expect(checksumMatches("abc", "A9993E364706816ABA3E25717850C26C9CD0D89D\n"));
    try std.testing.expect(!checksumMatches("abd", good));
    try std.testing.expect(!checksumMatches("abc", "a9993e364706816aba3e25717850c26c9cd0d89dx"));
    try std.testing.expect(!checksumMatches("abc", ""));
}

test "Maven coordinate validation and POM tags" {
    try std.testing.expect(valid("0.20.2"));
    try std.testing.expect(!valid("../../evil"));
    try std.testing.expectEqualStrings("runtime", tag("<scope>runtime</scope>", "scope").?);
}
test "Maven POM properties and coordinate validation" {
    try std.testing.expectEqualStrings("1.2", tag("<properties><lib.version>1.2</lib.version></properties>", "lib.version").?);
    try std.testing.expect(tag("<dependency><groupId>x</groupId></dependency>", "version") == null);
    try std.testing.expect(!valid("a/b"));
    try std.testing.expect(!valid("foo..bar"));
}
test "Maven POM dependency versions resolve local project and nested properties" {
    const xml = "<project><version>9.2</version><properties><lib.version>1.2</lib.version></properties><dependencies><dependency><version>${lib.version}</version></dependency></dependencies></project>";
    try std.testing.expectEqualStrings("9.2", resolvePomProperty(xml, "project.version", "9.2").?);
    try std.testing.expectEqualStrings("9.2", resolvePomProperty(xml, "version", "9.2").?);
    try std.testing.expectEqualStrings("1.2", resolvePomProperty(xml, "lib.version", "9.2").?);
    try std.testing.expect(resolvePomProperty(xml, "unknown", "9.2") == null);
}
