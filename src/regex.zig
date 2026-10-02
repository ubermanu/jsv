//! ECMA-262 flavoured regular expressions on top of PCRE2.

const std = @import("std");
const c = @import("pcre2");

pub const Error = error{ InvalidPattern, OutOfMemory };

code: *c.pcre2_code_8,
match_data: *c.pcre2_match_data_8,

const Regex = @This();

pub fn compile(source: []const u8) Error!Regex {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.heap.c_allocator);
    const pattern = try translate(std.heap.c_allocator, source, &buffer);

    const context = c.pcre2_compile_context_create_8(null) orelse return error.OutOfMemory;
    defer c.pcre2_compile_context_free_8(context);
    _ = c.pcre2_set_compile_extra_options_8(context, c.PCRE2_EXTRA_ALT_BSUX | c.PCRE2_EXTRA_ASCII_BSD | c.PCRE2_EXTRA_ASCII_BSW);

    var error_code: c_int = 0;
    var error_offset: usize = 0;
    const options = c.PCRE2_UTF | c.PCRE2_UCP | c.PCRE2_ALT_BSUX | c.PCRE2_DOLLAR_ENDONLY | c.PCRE2_ALLOW_EMPTY_CLASS;
    const code = c.pcre2_compile_8(pattern.ptr, pattern.len, options, &error_code, &error_offset, context) orelse
        return if (error_code == c.PCRE2_ERROR_HEAPLIMIT) error.OutOfMemory else error.InvalidPattern;
    errdefer c.pcre2_code_free_8(code);
    const match_data = c.pcre2_match_data_create_from_pattern_8(code, null) orelse return error.OutOfMemory;
    return .{ .code = code, .match_data = match_data };
}

/// ECMA-262 general category names that PCRE2 only knows by their short form.
const category_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Letter", "L" },             .{ "Cased_Letter", "L&" },          .{ "Uppercase_Letter", "Lu" },
    .{ "Lowercase_Letter", "Ll" },  .{ "Titlecase_Letter", "Lt" },      .{ "Modifier_Letter", "Lm" },
    .{ "Other_Letter", "Lo" },      .{ "Mark", "M" },                   .{ "Combining_Mark", "M" },
    .{ "Nonspacing_Mark", "Mn" },   .{ "Spacing_Mark", "Mc" },          .{ "Enclosing_Mark", "Me" },
    .{ "Number", "N" },             .{ "Decimal_Number", "Nd" },        .{ "digit", "Nd" },
    .{ "Letter_Number", "Nl" },     .{ "Other_Number", "No" },          .{ "Punctuation", "P" },
    .{ "punct", "P" },              .{ "Connector_Punctuation", "Pc" }, .{ "Dash_Punctuation", "Pd" },
    .{ "Open_Punctuation", "Ps" },  .{ "Close_Punctuation", "Pe" },     .{ "Initial_Punctuation", "Pi" },
    .{ "Final_Punctuation", "Pf" }, .{ "Other_Punctuation", "Po" },     .{ "Symbol", "S" },
    .{ "Math_Symbol", "Sm" },       .{ "Currency_Symbol", "Sc" },       .{ "Modifier_Symbol", "Sk" },
    .{ "Other_Symbol", "So" },      .{ "Separator", "Z" },              .{ "Space_Separator", "Zs" },
    .{ "Line_Separator", "Zl" },    .{ "Paragraph_Separator", "Zp" },   .{ "Other", "C" },
    .{ "Control", "Cc" },           .{ "cntrl", "Cc" },                 .{ "Format", "Cf" },
    .{ "Surrogate", "Cs" },         .{ "Private_Use", "Co" },           .{ "Unassigned", "Cn" },
});

/// Rewrites `\p{Letter}`-style escapes into names PCRE2 accepts.
fn translate(gpa: std.mem.Allocator, pattern: []const u8, out: *std.ArrayList(u8)) Error![]const u8 {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const ch = pattern[i];
        if (ch != '\\' or i + 2 >= pattern.len) {
            try out.append(gpa, ch);
            continue;
        }
        const next = pattern[i + 1];
        const end = if ((next == 'p' or next == 'P') and pattern[i + 2] == '{')
            std.mem.indexOfScalarPos(u8, pattern, i + 3, '}')
        else
            null;
        if (end) |e| {
            var name = pattern[i + 3 .. e];
            inline for (.{ "General_Category=", "gc=" }) |prefix| {
                if (std.mem.startsWith(u8, name, prefix)) name = name[prefix.len..];
            }
            try out.print(gpa, "\\{c}{{{s}}}", .{ next, category_aliases.get(name) orelse name });
            i = e;
        } else {
            try out.appendSlice(gpa, pattern[i .. i + 2]);
            i += 1;
        }
    }
    return out.items;
}

pub fn deinit(self: *Regex) void {
    c.pcre2_match_data_free_8(self.match_data);
    c.pcre2_code_free_8(self.code);
}

/// Returns whether the pattern matches anywhere in `input`.
pub fn search(self: *const Regex, input: []const u8) error{MatchFailed}!bool {
    const rc = c.pcre2_match_8(self.code, input.ptr, input.len, 0, 0, self.match_data, null);
    if (rc >= 0) return true;
    if (rc == c.PCRE2_ERROR_NOMATCH) return false;
    return error.MatchFailed;
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
    try expectMatch("^\\p{gc=Lu}$", "\u{C9}", true);
    try expectMatch("^[\\P{Nd}]$", "a", true);
    try expectMatch("^\\\\p{Letter}$", "\\p{Letter}", true);
    try expectMatch("^(?=.*\\d)[a-z0-9]+$", "abc", false);
    try expectMatch("(?<!a)b", "ab", false);
}

test "invalid patterns" {
    try std.testing.expectError(error.InvalidPattern, compile("^(abc"));
    try std.testing.expectError(error.InvalidPattern, compile("[a-"));
    try std.testing.expectError(error.InvalidPattern, compile("*a"));
}
