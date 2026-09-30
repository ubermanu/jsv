//! A subset of ECMA-262 regular expressions, as used by JSON Schema `pattern`.
//! Matching only answers "is there a match", so it runs as a backtracking
//! search that never revisits an (instruction, position) state.

const std = @import("std");
const unicode = @import("unicode.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidPattern, UnsupportedPattern, OutOfMemory };

const Range = struct { lo: u21, hi: u21 };

const Inst = union(enum) {
    char: u21,
    any,
    class: struct { ranges: []const Range, negated: bool },
    split: struct { a: u32, b: u32 },
    jmp: u32,
    line_start,
    line_end,
    word_boundary: bool,
    look: struct { negated: bool, end: u32 },
    match,
};

const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: struct { ranges: []const Range, negated: bool },
    line_start,
    line_end,
    word_boundary: bool,
    concat: []const Node,
    alt: []const Node,
    repeat: struct { node: *const Node, min: u32, max: ?u32 },
    look: struct { node: *const Node, negated: bool },
};

const max_program = 1 << 16;

arena: std.heap.ArenaAllocator,
program: []const Inst,

const Regex = @This();

pub fn compile(gpa: Allocator, pattern: []const u8) Error!Regex {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var parser: Parser = .{ .arena = arena.allocator(), .src = pattern };
    const node = try parser.parseAlt();
    if (parser.pos != pattern.len) return error.InvalidPattern;

    var program: std.ArrayList(Inst) = .empty;
    var emitter: Emitter = .{ .arena = arena.allocator(), .program = &program };
    try emitter.emit(node);
    try program.append(arena.allocator(), .match);
    return .{ .arena = arena, .program = program.items };
}

pub fn deinit(self: *Regex) void {
    self.arena.deinit();
}

/// Returns whether the pattern matches anywhere in `input`.
pub fn search(self: *const Regex, gpa: Allocator, input: []const u8) Allocator.Error!bool {
    var visited = try std.DynamicBitSetUnmanaged.initEmpty(gpa, self.program.len * (input.len + 1));
    defer visited.deinit(gpa);
    var start: usize = 0;
    while (true) {
        if (try self.run(gpa, input, 0, start, &visited)) return true;
        if (start >= input.len) return false;
        start += decode(input, start).len;
    }
}

fn run(self: *const Regex, gpa: Allocator, input: []const u8, pc0: u32, sp0: usize, visited: *std.DynamicBitSetUnmanaged) Allocator.Error!bool {
    const Thread = struct { pc: u32, sp: usize };
    var stack: std.ArrayList(Thread) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .pc = pc0, .sp = sp0 });

    while (stack.pop()) |thread| {
        var pc = thread.pc;
        var sp = thread.sp;
        while (true) {
            const state = pc * (input.len + 1) + sp;
            if (visited.isSet(state)) break;
            visited.set(state);
            switch (self.program[pc]) {
                .match => return true,
                .char => |c| {
                    if (sp >= input.len) break;
                    const cp = decode(input, sp);
                    if (cp.value != c) break;
                    sp += cp.len;
                    pc += 1;
                },
                .any => {
                    if (sp >= input.len) break;
                    const cp = decode(input, sp);
                    if (isLineTerminator(cp.value)) break;
                    sp += cp.len;
                    pc += 1;
                },
                .class => |class| {
                    if (sp >= input.len) break;
                    const cp = decode(input, sp);
                    if (inRanges(class.ranges, cp.value) == class.negated) break;
                    sp += cp.len;
                    pc += 1;
                },
                .split => |s| {
                    try stack.append(gpa, .{ .pc = s.b, .sp = sp });
                    pc = s.a;
                },
                .jmp => |target| pc = target,
                .line_start => {
                    if (sp != 0) break;
                    pc += 1;
                },
                .line_end => {
                    if (sp != input.len) break;
                    pc += 1;
                },
                .word_boundary => |negated| {
                    const before = sp > 0 and isWordChar(input[sp - 1]);
                    const after = sp < input.len and isWordChar(input[sp]);
                    if ((before != after) == negated) break;
                    pc += 1;
                },
                .look => |look| {
                    var inner = try std.DynamicBitSetUnmanaged.initEmpty(gpa, visited.bit_length);
                    defer inner.deinit(gpa);
                    if (try self.run(gpa, input, pc + 1, sp, &inner) == look.negated) break;
                    pc = look.end;
                },
            }
        }
    }
    return false;
}

const Codepoint = struct { value: u21, len: usize };

fn decode(input: []const u8, i: usize) Codepoint {
    const len = std.unicode.utf8ByteSequenceLength(input[i]) catch return .{ .value = input[i], .len = 1 };
    if (i + len > input.len) return .{ .value = input[i], .len = 1 };
    const value = std.unicode.utf8Decode(input[i .. i + len]) catch return .{ .value = input[i], .len = 1 };
    return .{ .value = value, .len = len };
}

fn isLineTerminator(c: u21) bool {
    return c == '\n' or c == '\r' or c == 0x2028 or c == 0x2029;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `ranges` must be sorted and disjoint.
fn inRanges(ranges: []const Range, c: u21) bool {
    var lo: usize = 0;
    var hi = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (c < ranges[mid].lo) {
            hi = mid;
        } else if (c > ranges[mid].hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

fn normalize(ranges: []Range) []Range {
    if (ranges.len == 0) return ranges;
    std.mem.sort(Range, ranges, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            return a.lo < b.lo;
        }
    }.lessThan);
    var len: usize = 1;
    for (ranges[1..]) |r| {
        const last = &ranges[len - 1];
        if (r.lo <= last.hi +| 1) {
            last.hi = @max(last.hi, r.hi);
        } else {
            ranges[len] = r;
            len += 1;
        }
    }
    return ranges[0..len];
}

const digit_ranges = [_]Range{.{ .lo = '0', .hi = '9' }};
const word_ranges = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };
const space_ranges = [_]Range{
    .{ .lo = '\t', .hi = '\r' },     .{ .lo = ' ', .hi = ' ' },       .{ .lo = 0xa0, .hi = 0xa0 },
    .{ .lo = 0x1680, .hi = 0x1680 }, .{ .lo = 0x2000, .hi = 0x200a }, .{ .lo = 0x2028, .hi = 0x2029 },
    .{ .lo = 0x202f, .hi = 0x202f }, .{ .lo = 0x205f, .hi = 0x205f }, .{ .lo = 0x3000, .hi = 0x3000 },
    .{ .lo = 0xfeff, .hi = 0xfeff },
};

const Set = struct { ranges: []const Range, negated: bool };

fn shorthand(c: u8) ?Set {
    return switch (c) {
        'd' => .{ .ranges = &digit_ranges, .negated = false },
        'D' => .{ .ranges = &digit_ranges, .negated = true },
        'w' => .{ .ranges = &word_ranges, .negated = false },
        'W' => .{ .ranges = &word_ranges, .negated = true },
        's' => .{ .ranges = &space_ranges, .negated = false },
        'S' => .{ .ranges = &space_ranges, .negated = true },
        else => null,
    };
}

const category_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Letter", "L" },             .{ "Cased_Letter", "LC" },          .{ "Uppercase_Letter", "Lu" },
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

/// Returns the code points of a Unicode general category such as `L`, `Lu` or `Letter`.
fn category(arena: Allocator, text: []const u8) Error![]const Range {
    var name = text;
    inline for (.{ "General_Category=", "gc=" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) name = name[prefix.len..];
    }
    name = category_aliases.get(name) orelse name;
    var ranges: std.ArrayList(Range) = .empty;
    inline for (unicode.categories) |entry| {
        const matches = if (std.mem.eql(u8, name, "LC"))
            std.mem.eql(u8, entry[0], "Lu") or std.mem.eql(u8, entry[0], "Ll") or std.mem.eql(u8, entry[0], "Lt")
        else
            std.mem.eql(u8, name, entry[0]) or name.len == 1 and name[0] == entry[0][0];
        if (matches) for (entry[1]) |r| try ranges.append(arena, .{ .lo = r[0], .hi = r[1] });
    }
    if (ranges.items.len == 0) return error.UnsupportedPattern;
    return normalize(ranges.items);
}

/// Appends the complement of sorted, disjoint `ranges`.
fn appendComplement(arena: Allocator, out: *std.ArrayList(Range), ranges: []const Range) !void {
    var next: u21 = 0;
    for (ranges) |r| {
        if (r.lo > next) try out.append(arena, .{ .lo = next, .hi = r.lo - 1 });
        next = r.hi + 1;
    }
    if (next <= 0x10ffff) try out.append(arena, .{ .lo = next, .hi = 0x10ffff });
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() == c) {
            p.pos += 1;
            return true;
        }
        return false;
    }

    fn parseAlt(p: *Parser) Error!Node {
        var branches: std.ArrayList(Node) = .empty;
        try branches.append(p.arena, try p.parseConcat());
        while (p.eat('|')) try branches.append(p.arena, try p.parseConcat());
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = branches.items };
    }

    fn parseConcat(p: *Parser) Error!Node {
        var items: std.ArrayList(Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            const atom = try p.parseAtom();
            try items.append(p.arena, try p.parseQuantifier(atom));
        }
        return switch (items.items.len) {
            0 => .empty,
            1 => items.items[0],
            else => .{ .concat = items.items },
        };
    }

    fn parseQuantifier(p: *Parser, atom: Node) Error!Node {
        var min: u32 = undefined;
        var max: ?u32 = undefined;
        const c = p.peek() orelse return atom;
        switch (c) {
            '*' => {
                p.pos += 1;
                min = 0;
                max = null;
            },
            '+' => {
                p.pos += 1;
                min = 1;
                max = null;
            },
            '?' => {
                p.pos += 1;
                min = 0;
                max = 1;
            },
            '{' => {
                const bounds = p.parseBounds() orelse return atom;
                min = bounds.min;
                max = bounds.max;
            },
            else => return atom,
        }
        _ = p.eat('?');
        switch (atom) {
            .line_start, .line_end, .word_boundary => return error.InvalidPattern,
            else => {},
        }
        if (max) |m| if (m < min) return error.InvalidPattern;
        const node = try p.arena.create(Node);
        node.* = atom;
        return .{ .repeat = .{ .node = node, .min = min, .max = max } };
    }

    fn parseBounds(p: *Parser) ?struct { min: u32, max: ?u32 } {
        const start = p.pos;
        p.pos += 1;
        const min = p.parseNumber() orelse {
            p.pos = start;
            return null;
        };
        var max: ?u32 = min;
        if (p.eat(',')) max = p.parseNumber();
        if (!p.eat('}')) {
            p.pos = start;
            return null;
        }
        return .{ .min = min, .max = max };
    }

    fn parseNumber(p: *Parser) ?u32 {
        const start = p.pos;
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            p.pos += 1;
        }
        if (p.pos == start) return null;
        return std.fmt.parseInt(u32, p.src[start..p.pos], 10) catch std.math.maxInt(u32);
    }

    fn parseAtom(p: *Parser) Error!Node {
        const c = p.src[p.pos];
        switch (c) {
            '^' => {
                p.pos += 1;
                return .line_start;
            },
            '$' => {
                p.pos += 1;
                return .line_end;
            },
            '.' => {
                p.pos += 1;
                return .any;
            },
            '(' => return p.parseGroup(),
            '[' => return p.parseClass(),
            '\\' => return p.parseEscape(),
            '*', '+', '?' => return error.InvalidPattern,
            '{' => {
                if (p.parseBounds() != null) return error.InvalidPattern;
                p.pos += 1;
                return .{ .char = '{' };
            },
            else => return .{ .char = try p.parseLiteral() },
        }
    }

    fn parseLiteral(p: *Parser) Error!u21 {
        const cp = decode(p.src, p.pos);
        p.pos += cp.len;
        return cp.value;
    }

    fn parseGroup(p: *Parser) Error!Node {
        p.pos += 1;
        var look: ?bool = null;
        if (p.eat('?')) {
            if (p.eat(':')) {} else if (p.eat('=')) {
                look = false;
            } else if (p.eat('!')) {
                look = true;
            } else if (p.eat('<')) {
                if (p.peek() == '=' or p.peek() == '!') return error.UnsupportedPattern;
                while (p.peek()) |c| {
                    p.pos += 1;
                    if (c == '>') break;
                } else return error.InvalidPattern;
            } else return error.InvalidPattern;
        }
        const inner = try p.parseAlt();
        if (!p.eat(')')) return error.InvalidPattern;
        const negated = look orelse return inner;
        const node = try p.arena.create(Node);
        node.* = inner;
        return .{ .look = .{ .node = node, .negated = negated } };
    }

    /// Parses the letter of a `\d`-like shorthand or a `\p{...}` property escape.
    fn parseSet(p: *Parser) Error!?Set {
        const c = p.src[p.pos];
        if (shorthand(c)) |s| {
            p.pos += 1;
            return s;
        }
        if (c != 'p' and c != 'P') return null;
        p.pos += 1;
        if (!p.eat('{')) return error.InvalidPattern;
        const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, '}') orelse return error.InvalidPattern;
        const ranges = try category(p.arena, p.src[p.pos..end]);
        p.pos = end + 1;
        return .{ .ranges = ranges, .negated = c == 'P' };
    }

    fn parseEscape(p: *Parser) Error!Node {
        p.pos += 1;
        const c = p.peek() orelse return error.InvalidPattern;
        if (try p.parseSet()) |s| return .{ .class = .{ .ranges = s.ranges, .negated = s.negated } };
        switch (c) {
            'b' => {
                p.pos += 1;
                return .{ .word_boundary = false };
            },
            'B' => {
                p.pos += 1;
                return .{ .word_boundary = true };
            },
            '1'...'9' => return error.UnsupportedPattern,
            else => return .{ .char = try p.parseCharEscape() },
        }
    }

    /// Parses the character after a backslash that stands for a single code point.
    fn parseCharEscape(p: *Parser) Error!u21 {
        const c = p.src[p.pos];
        p.pos += 1;
        return switch (c) {
            't' => '\t',
            'n' => '\n',
            'v' => 0x0b,
            'f' => 0x0c,
            'r' => '\r',
            '0' => 0,
            'c' => {
                const letter = p.peek() orelse return error.InvalidPattern;
                if (!std.ascii.isAlphabetic(letter)) return error.InvalidPattern;
                p.pos += 1;
                return letter % 32;
            },
            'x' => p.parseHex(2),
            'u' => p.parseUnicodeEscape(),
            'k' => error.UnsupportedPattern,
            else => {
                if (std.ascii.isAlphanumeric(c)) return error.InvalidPattern;
                p.pos -= 1;
                return p.parseLiteral();
            },
        };
    }

    fn parseUnicodeEscape(p: *Parser) Error!u21 {
        if (p.eat('{')) {
            const end = std.mem.indexOfScalarPos(u8, p.src, p.pos, '}') orelse return error.InvalidPattern;
            const value = std.fmt.parseInt(u21, p.src[p.pos..end], 16) catch return error.InvalidPattern;
            p.pos = end + 1;
            return value;
        }
        const high = try p.parseHex(4);
        if (high >= 0xd800 and high <= 0xdbff and std.mem.startsWith(u8, p.src[p.pos..], "\\u")) {
            const save = p.pos;
            p.pos += 2;
            const low = p.parseHex(4) catch 0;
            if (low >= 0xdc00 and low <= 0xdfff) return 0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00);
            p.pos = save;
        }
        return high;
    }

    fn parseHex(p: *Parser, comptime digits: usize) Error!u21 {
        if (p.pos + digits > p.src.len) return error.InvalidPattern;
        const value = std.fmt.parseInt(u21, p.src[p.pos .. p.pos + digits], 16) catch return error.InvalidPattern;
        p.pos += digits;
        return value;
    }

    fn parseClass(p: *Parser) Error!Node {
        p.pos += 1;
        const negated = p.eat('^');
        var ranges: std.ArrayList(Range) = .empty;
        while (true) {
            const c = p.peek() orelse return error.InvalidPattern;
            if (c == ']') {
                p.pos += 1;
                break;
            }
            const lo = try p.parseClassAtom(&ranges) orelse continue;
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                p.pos += 1;
                const hi = try p.parseClassAtom(&ranges) orelse return error.InvalidPattern;
                if (hi < lo) return error.InvalidPattern;
                try ranges.append(p.arena, .{ .lo = lo, .hi = hi });
            } else {
                try ranges.append(p.arena, .{ .lo = lo, .hi = lo });
            }
        }
        return .{ .class = .{ .ranges = normalize(ranges.items), .negated = negated } };
    }

    /// Returns a single code point, or null after appending a shorthand class.
    fn parseClassAtom(p: *Parser, ranges: *std.ArrayList(Range)) Error!?u21 {
        if (!p.eat('\\')) return try p.parseLiteral();
        const c = p.peek() orelse return error.InvalidPattern;
        if (try p.parseSet()) |s| {
            if (s.negated) {
                try appendComplement(p.arena, ranges, s.ranges);
            } else {
                try ranges.appendSlice(p.arena, s.ranges);
            }
            return null;
        }
        if (c == 'b') {
            p.pos += 1;
            return 0x08;
        }
        if (c == '-') {
            p.pos += 1;
            return '-';
        }
        return try p.parseCharEscape();
    }
};

const Emitter = struct {
    arena: Allocator,
    program: *std.ArrayList(Inst),

    fn here(e: *Emitter) u32 {
        return @intCast(e.program.items.len);
    }

    fn push(e: *Emitter, inst: Inst) Error!u32 {
        if (e.program.items.len >= max_program) return error.UnsupportedPattern;
        const at = e.here();
        try e.program.append(e.arena, inst);
        return at;
    }

    fn emit(e: *Emitter, node: Node) Error!void {
        switch (node) {
            .empty => {},
            .char => |c| _ = try e.push(.{ .char = c }),
            .any => _ = try e.push(.any),
            .class => |c| _ = try e.push(.{ .class = .{ .ranges = c.ranges, .negated = c.negated } }),
            .line_start => _ = try e.push(.line_start),
            .line_end => _ = try e.push(.line_end),
            .word_boundary => |negated| _ = try e.push(.{ .word_boundary = negated }),
            .concat => |items| for (items) |item| try e.emit(item),
            .alt => |branches| {
                var jumps: std.ArrayList(u32) = .empty;
                for (branches, 0..) |branch, i| {
                    if (i + 1 < branches.len) {
                        const split = try e.push(.{ .split = .{ .a = 0, .b = 0 } });
                        e.program.items[split].split.a = e.here();
                        try e.emit(branch);
                        try jumps.append(e.arena, try e.push(.{ .jmp = 0 }));
                        e.program.items[split].split.b = e.here();
                    } else {
                        try e.emit(branch);
                    }
                }
                for (jumps.items) |jump| e.program.items[jump] = .{ .jmp = e.here() };
            },
            .repeat => |r| {
                var i: u32 = 0;
                while (i < r.min) : (i += 1) try e.emit(r.node.*);
                if (r.max) |max| {
                    var splits: std.ArrayList(u32) = .empty;
                    while (i < max) : (i += 1) {
                        const split = try e.push(.{ .split = .{ .a = 0, .b = 0 } });
                        e.program.items[split].split.a = e.here();
                        try splits.append(e.arena, split);
                        try e.emit(r.node.*);
                    }
                    for (splits.items) |split| e.program.items[split].split.b = e.here();
                } else {
                    const split = try e.push(.{ .split = .{ .a = 0, .b = 0 } });
                    e.program.items[split].split.a = e.here();
                    try e.emit(r.node.*);
                    _ = try e.push(.{ .jmp = split });
                    e.program.items[split].split.b = e.here();
                }
            },
            .look => |l| {
                const look = try e.push(.{ .look = .{ .negated = l.negated, .end = 0 } });
                try e.emit(l.node.*);
                _ = try e.push(.match);
                e.program.items[look].look.end = e.here();
            },
        }
    }
};

fn expectMatch(pattern: []const u8, input: []const u8, expected: bool) !void {
    var re = try compile(std.testing.allocator, pattern);
    defer re.deinit();
    std.testing.expectEqual(expected, try re.search(std.testing.allocator, input)) catch |err| {
        std.debug.print("pattern {s} on {s}\n", .{ pattern, input });
        return err;
    };
}

test "search is unanchored unless the pattern says otherwise" {
    try expectMatch("b", "abc", true);
    try expectMatch("^b", "abc", false);
    try expectMatch("c$", "abc", true);
    try expectMatch("^abc$", "abcd", false);
    try expectMatch("", "", true);
}

test "quantifiers and alternation" {
    try expectMatch("^a*$", "aaaa", true);
    try expectMatch("^a+$", "", false);
    try expectMatch("^ab?c$", "ac", true);
    try expectMatch("^a{2,3}$", "aaaa", false);
    try expectMatch("^a{2,}$", "aaaaa", true);
    try expectMatch("^a{2}$", "aa", true);
    try expectMatch("^(cat|dog)s?$", "dogs", true);
    try expectMatch("^(cat|dog)s?$", "cow", false);
    try expectMatch("^(a*)*$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaab", false);
    try expectMatch("x{", "x{", true);
    try expectMatch("^.+?$", "abc", true);
}

test "classes and escapes" {
    try expectMatch("^[a-z0-9_-]+$", "my-package_1", true);
    try expectMatch("^[^a-z]+$", "ABC", true);
    try expectMatch("^[^a-z]+$", "AbC", false);
    try expectMatch("^\\d+$", "123", true);
    try expectMatch("^\\d+$", "\u{0660}", false);
    try expectMatch("^\\w+$", "\u{e9}", false);
    try expectMatch("^\\s$", "\u{3000}", true);
    try expectMatch("^[\\D]$", "a", true);
    try expectMatch("^\\u00e9$", "\u{e9}", true);
    try expectMatch("^\\.$", ".", true);
    try expectMatch("\\bword\\b", "a word here", true);
    try expectMatch("\\bword\\b", "swordfish", false);
    try expectMatch("^.$", "\u{1F600}", true);
    try expectMatch("^.$", "\n", false);
    try expectMatch("^[z-z\\da-c]+$", "a1z", true);
}

test "unicode property escapes" {
    try expectMatch("^\\p{Letter}+$", "\u{e9}t\u{e9}", true);
    try expectMatch("^\\p{L}+$", "a1", false);
    try expectMatch("^\\p{Lu}$", "\u{C9}", true);
    try expectMatch("^\\P{Lu}$", "\u{C9}", false);
    try expectMatch("^[\\p{Nd}_]+$", "\u{0660}_", true);
    try expectMatch("^\\p{gc=Zs}$", " ", true);
    try std.testing.expectError(error.UnsupportedPattern, compile(std.testing.allocator, "\\p{Script=Greek}"));
}

test "lookahead" {
    try expectMatch("^(?=.*\\d)[a-z0-9]+$", "abc1", true);
    try expectMatch("^(?=.*\\d)[a-z0-9]+$", "abc", false);
    try expectMatch("^(?!foo).*$", "foobar", false);
    try expectMatch("^(?:a|b)+$", "abba", true);
}

test "invalid and unsupported patterns" {
    try std.testing.expectError(error.InvalidPattern, compile(std.testing.allocator, "^(abc"));
    try std.testing.expectError(error.InvalidPattern, compile(std.testing.allocator, "[a-"));
    try std.testing.expectError(error.InvalidPattern, compile(std.testing.allocator, "*a"));
    try std.testing.expectError(error.InvalidPattern, compile(std.testing.allocator, "\\a"));
    try std.testing.expectError(error.UnsupportedPattern, compile(std.testing.allocator, "(a)\\1"));
}
