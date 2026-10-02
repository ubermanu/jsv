//! ECMA-262 regular expressions, backed by libregexp from QuickJS-ng.

const std = @import("std");

pub const Error = error{ InvalidPattern, OutOfMemory };

const flag_unicode = 1 << 4;
const latin1 = 0;
const utf16 = 1;

extern fn lre_compile(plen: *c_int, error_msg: [*]u8, error_msg_size: c_int, buf: [*]const u8, buf_len: usize, re_flags: c_int, opaque_ptr: ?*anyopaque) ?[*]u8;
extern fn lre_get_capture_count(bc_buf: [*]const u8) c_int;
extern fn lre_exec(capture: [*]?[*]u8, bc_buf: [*]const u8, cbuf: [*]const u8, cindex: c_int, clen: c_int, cbuf_type: c_int, opaque_ptr: ?*anyopaque) c_int;

/// Bytes of stack libregexp may use for its recursive parser.
const stack_budget = 256 * 1024;
threadlocal var stack_base: usize = 0;

export fn lre_check_stack_overflow(_: ?*anyopaque, alloca_size: usize) bool {
    return stack_base -| @frameAddress() + alloca_size > stack_budget;
}

export fn lre_check_timeout(_: ?*anyopaque) c_int {
    return 0;
}

export fn lre_realloc(_: ?*anyopaque, ptr: ?*anyopaque, size: usize) ?*anyopaque {
    if (size == 0) {
        std.c.free(ptr);
        return null;
    }
    return std.c.realloc(ptr, size);
}

bytecode: [*]u8,

const Regex = @This();

pub fn compile(pattern: []const u8) Error!Regex {
    // libregexp finds the end of the pattern by reading a NUL byte past it.
    const source = try std.heap.c_allocator.dupeZ(u8, pattern);
    defer std.heap.c_allocator.free(source);
    stack_base = @frameAddress();
    var message: [64]u8 = undefined;
    var len: c_int = 0;
    const bytecode = lre_compile(&len, &message, message.len, source.ptr, source.len, flag_unicode, null) orelse
        return if (std.mem.startsWith(u8, std.mem.sliceTo(&message, 0), "out of memory")) error.OutOfMemory else error.InvalidPattern;
    return .{ .bytecode = bytecode };
}

pub fn deinit(self: *Regex) void {
    std.c.free(self.bytecode);
}

/// Returns whether the pattern matches anywhere in `input`.
pub fn search(self: *const Regex, input: []const u8) error{ MatchFailed, OutOfMemory }!bool {
    const gpa = std.heap.c_allocator;
    const capture = try gpa.alloc(?[*]u8, @intCast(lre_get_capture_count(self.bytecode) * 2));
    defer gpa.free(capture);

    const rc = if (isAscii(input))
        lre_exec(capture.ptr, self.bytecode, input.ptr, 0, std.math.cast(c_int, input.len) orelse return error.MatchFailed, latin1, null)
    else blk: {
        const units = std.unicode.utf8ToUtf16LeAlloc(gpa, input) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MatchFailed,
        };
        defer gpa.free(units);
        break :blk lre_exec(capture.ptr, self.bytecode, @ptrCast(units.ptr), 0, std.math.cast(c_int, units.len) orelse return error.MatchFailed, utf16, null);
    };
    if (rc < 0) return error.MatchFailed;
    return rc == 1;
}

fn isAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80) return false;
    return true;
}

fn expectMatch(pattern: []const u8, input: []const u8, expected: bool) !void {
    var re = compile(pattern) catch |err| {
        std.debug.print("pattern {s} does not compile\n", .{pattern});
        return err;
    };
    defer re.deinit();
    std.testing.expectEqual(expected, try re.search(input)) catch |err| {
        std.debug.print("pattern {s} on {s}\n", .{ pattern, input });
        return err;
    };
}

test "search is unanchored unless the pattern says otherwise" {
    try expectMatch("b", "abc", true);
    try expectMatch("^b", "abc", false);
    try expectMatch("c$", "abc", true);
    try expectMatch("c$", "abc\n", false);
    try expectMatch("", "", true);
}

test "escapes follow ECMA-262" {
    try expectMatch("^\\d+$", "\u{0660}", false);
    try expectMatch("^\\w+$", "\u{e9}", false);
    try expectMatch("\\bword\\b", "swordfish", false);
    try expectMatch("^\\s$", "\u{3000}", true);
    try expectMatch("^\\u00e9$", "\u{e9}", true);
    try expectMatch("^.$", "\u{1F600}", true);
    try expectMatch("a[]", "a", false);
    try expectMatch("^[^]$", "\n", true);
}

test "unicode properties and lookaround" {
    try expectMatch("^\\p{Letter}+$", "\u{e9}t\u{e9}", true);
    try expectMatch("^\\p{L}+$", "a1", false);
    try expectMatch("^\\p{Script=Greek}$", "\u{3b1}", true);
    try expectMatch("^(?=.*\\d)[a-z0-9]+$", "abc", false);
    try expectMatch("(?<=a+)b", "aab", true);
}

test "only ECMA-262 syntax compiles" {
    inline for (.{ "^(abc", "[a-", "*a", "\\a", "(?P<n>a)", "(?i)a", "(?#comment)" }) |pattern| {
        std.testing.expectError(error.InvalidPattern, compile(pattern)) catch |err| {
            std.debug.print("pattern {s} compiled\n", .{pattern});
            return err;
        };
    }
}

test "deeply nested patterns fail instead of overflowing the stack" {
    const pattern = "(" ** 100_000;
    try std.testing.expectError(error.InvalidPattern, compile(pattern));
}
