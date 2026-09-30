const std = @import("std");
const Allocator = std.mem.Allocator;

const Parts = struct {
    scheme: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};

fn split(text: []const u8) Parts {
    var parts: Parts = .{};
    var rest = text;
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| {
        parts.fragment = rest[i + 1 ..];
        rest = rest[0..i];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
        parts.query = rest[i + 1 ..];
        rest = rest[0..i];
    }
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
        if (i > 0 and isScheme(rest[0..i])) {
            parts.scheme = rest[0..i];
            rest = rest[i + 1 ..];
        }
    }
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        parts.authority = rest[0..end];
        rest = rest[end..];
    }
    parts.path = rest;
    return parts;
}

fn isScheme(s: []const u8) bool {
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

pub fn isAbsolute(text: []const u8) bool {
    return split(text).scheme != null;
}

/// Resolves `ref` against `base` following RFC 3986 section 5.2.
pub fn resolve(gpa: Allocator, base: []const u8, ref: []const u8) ![]u8 {
    const r = split(ref);
    const b = split(base);
    var t: Parts = .{ .fragment = r.fragment };
    var merged: ?[]u8 = null;
    defer if (merged) |m| gpa.free(m);

    if (r.scheme != null) {
        t.scheme = r.scheme;
        t.authority = r.authority;
        t.path = r.path;
        t.query = r.query;
    } else {
        t.scheme = b.scheme;
        if (r.authority != null) {
            t.authority = r.authority;
            t.path = r.path;
            t.query = r.query;
        } else {
            t.authority = b.authority;
            if (r.path.len == 0) {
                t.path = b.path;
                t.query = r.query orelse b.query;
            } else {
                t.query = r.query;
                if (r.path[0] == '/') {
                    t.path = r.path;
                } else if (b.authority != null and b.path.len == 0) {
                    merged = try std.mem.concat(gpa, u8, &.{ "/", r.path });
                    t.path = merged.?;
                } else {
                    const dir = if (std.mem.lastIndexOfScalar(u8, b.path, '/')) |i| b.path[0 .. i + 1] else "";
                    merged = try std.mem.concat(gpa, u8, &.{ dir, r.path });
                    t.path = merged.?;
                }
            }
        }
    }

    const path = try removeDotSegments(gpa, t.path);
    defer gpa.free(path);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (t.scheme) |s| try out.print(gpa, "{s}:", .{s});
    if (t.authority) |a| try out.print(gpa, "//{s}", .{a});
    try out.appendSlice(gpa, path);
    if (t.query) |q| try out.print(gpa, "?{s}", .{q});
    if (t.fragment) |f| try out.print(gpa, "#{s}", .{f});
    return out.toOwnedSlice(gpa);
}

fn removeDotSegments(gpa: Allocator, path: []const u8) ![]u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(gpa);
    var it = std.mem.splitScalar(u8, path, '/');
    const absolute = path.len > 0 and path[0] == '/';
    if (absolute) _ = it.next();
    var trailing = false;
    while (it.next()) |segment| {
        trailing = false;
        if (std.mem.eql(u8, segment, ".")) {
            trailing = true;
        } else if (std.mem.eql(u8, segment, "..")) {
            _ = segments.pop();
            trailing = true;
        } else {
            try segments.append(gpa, segment);
        }
    }
    if (trailing) try segments.append(gpa, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (segments.items, 0..) |segment, i| {
        if (i > 0 or absolute) try out.append(gpa, '/');
        try out.appendSlice(gpa, segment);
    }
    return out.toOwnedSlice(gpa);
}

/// Splits a URI into the part before `#` and the fragment (empty if absent).
pub fn splitFragment(text: []const u8) struct { []const u8, []const u8 } {
    const i = std.mem.indexOfScalar(u8, text, '#') orelse return .{ text, "" };
    return .{ text[0..i], text[i + 1 ..] };
}

pub fn percentDecode(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(gpa, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, text[i]);
    }
    return out.toOwnedSlice(gpa);
}

/// Converts an absolute file system path into a `file://` URL.
pub fn fromPath(gpa: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    if (path.len == 0 or (path[0] != '/' and path[0] != '\\')) try out.append(gpa, '/');
    for (path) |c| {
        if (c == '\\') {
            try out.append(gpa, '/');
        } else if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-._~!$&'()*+,;=:@", c) != null) {
            try out.append(gpa, c);
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Converts a `file://` URL back into a file system path.
pub fn toPath(gpa: Allocator, url: []const u8) ![]u8 {
    const parts = split(url);
    var path = parts.path;
    if (path.len >= 3 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == ':') path = path[1..];
    return percentDecode(gpa, path);
}

fn expectResolve(base: []const u8, ref: []const u8, expected: []const u8) !void {
    const actual = try resolve(std.testing.allocator, base, ref);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "resolve follows the RFC 3986 examples" {
    const base = "http://a/b/c/d;p?q";
    try expectResolve(base, "g", "http://a/b/c/g");
    try expectResolve(base, "./g", "http://a/b/c/g");
    try expectResolve(base, "g/", "http://a/b/c/g/");
    try expectResolve(base, "/g", "http://a/g");
    try expectResolve(base, "//g", "http://g");
    try expectResolve(base, "?y", "http://a/b/c/d;p?y");
    try expectResolve(base, "#s", "http://a/b/c/d;p?q#s");
    try expectResolve(base, "", "http://a/b/c/d;p?q");
    try expectResolve(base, ".", "http://a/b/c/");
    try expectResolve(base, "..", "http://a/b/");
    try expectResolve(base, "../g", "http://a/b/g");
    try expectResolve(base, "../../../g", "http://a/g");
    try expectResolve(base, "g;x=1/../y", "http://a/b/c/y");
    try expectResolve(base, "urn:x:y", "urn:x:y");
}

test "resolve handles file URLs and URNs" {
    try expectResolve("file:///s/data/rope.json", "../schema/item.json", "file:///s/schema/item.json");
    try expectResolve("urn:uuid:deadbeef", "#/$defs/a", "urn:uuid:deadbeef#/$defs/a");
    try expectResolve("", "item.json", "item.json");
}

test "file paths round trip through URLs" {
    const gpa = std.testing.allocator;
    const url = try fromPath(gpa, "/tmp/my schemas/a.json");
    defer gpa.free(url);
    try std.testing.expectEqualStrings("file:///tmp/my%20schemas/a.json", url);
    const path = try toPath(gpa, url);
    defer gpa.free(path);
    try std.testing.expectEqualStrings("/tmp/my schemas/a.json", path);

    const windows = try fromPath(gpa, "C:\\s\\a.json");
    defer gpa.free(windows);
    try std.testing.expectEqualStrings("file:///C:/s/a.json", windows);
    const windows_path = try toPath(gpa, windows);
    defer gpa.free(windows_path);
    try std.testing.expectEqualStrings("C:/s/a.json", windows_path);
}
