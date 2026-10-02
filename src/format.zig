//! Checks for the `format` keyword. Drafts 4, 6 and 7 treat formats as assertions.

const std = @import("std");
const Regex = @import("regex.zig");

/// Returns whether `value` matches `format`, or null for an unknown format.
/// `rfc1123` selects the draft 4 and 6 hostname rules.
pub fn check(arena: std.mem.Allocator, format: []const u8, value: []const u8, rfc1123: bool) ?bool {
    const Format = enum { date, @"date-time", time, email, hostname, ipv4, ipv6, uri, @"uri-reference", iri, @"iri-reference", @"json-pointer", @"relative-json-pointer", regex, @"uri-template" };
    return switch (std.meta.stringToEnum(Format, format) orelse return null) {
        .date => isDate(value),
        .@"date-time" => isDateTime(value),
        .time => isTime(value),
        .email => isEmail(arena, value),
        .hostname => isHostname(arena, value, rfc1123),
        .ipv4 => isIpv4(value),
        .ipv6 => isIpv6(value),
        .uri => isUri(value, .{ .absolute = true, .unicode = false }),
        .@"uri-reference" => isUri(value, .{ .absolute = false, .unicode = false }),
        .iri => isUri(value, .{ .absolute = true, .unicode = true }),
        .@"iri-reference" => isUri(value, .{ .absolute = false, .unicode = true }),
        .@"json-pointer" => isJsonPointer(value),
        .@"relative-json-pointer" => isRelativeJsonPointer(value),
        .regex => isRegex(value),
        .@"uri-template" => isUriTemplate(value),
    };
}

fn digits(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var n: u32 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

fn isDate(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    const year = digits(s[0..4]) orelse return false;
    const month = digits(s[5..7]) orelse return false;
    const day = digits(s[8..10]) orelse return false;
    if (month < 1 or month > 12 or day < 1) return false;
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const days = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return day <= days[month - 1];
}

fn isTime(s: []const u8) bool {
    if (s.len < 9 or s[2] != ':' or s[5] != ':') return false;
    const hour = digits(s[0..2]) orelse return false;
    const minute = digits(s[3..5]) orelse return false;
    const second = digits(s[6..8]) orelse return false;
    var rest = s[8..];
    if (rest[0] == '.') {
        var i: usize = 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i == 1) return false;
        rest = rest[i..];
    }
    var offset: i32 = 0;
    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) {} else {
        if (rest.len != 6 or (rest[0] != '+' and rest[0] != '-') or rest[3] != ':') return false;
        const offset_hour = digits(rest[1..3]) orelse return false;
        const offset_minute = digits(rest[4..6]) orelse return false;
        if (offset_hour > 23 or offset_minute > 59) return false;
        offset = @intCast(offset_hour * 60 + offset_minute);
        if (rest[0] == '-') offset = -offset;
    }
    if (hour > 23 or minute > 59 or second > 60) return false;
    if (second == 60) {
        const utc = @mod(@as(i32, @intCast(hour * 60 + minute)) - offset, 24 * 60);
        return utc == 23 * 60 + 59;
    }
    return true;
}

fn isDateTime(s: []const u8) bool {
    if (s.len < 11 or (s[10] != 'T' and s[10] != 't')) return false;
    return isDate(s[0..10]) and isTime(s[11..]);
}

fn isHostname(arena: std.mem.Allocator, s: []const u8, rfc1123: bool) bool {
    if (s.len == 0 or s.len > 253) return false;
    var labels = std.mem.splitScalar(u8, s, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return false;
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
        }
        if (rfc1123 or label.len < 4 or label[2] != '-' or label[3] != '-') continue;
        if (!std.mem.startsWith(u8, label, "xn--")) return false;
        const decoded = decodePunycode(arena, label[4..]) catch return false;
        if (!isIdnaLabel(decoded)) return false;
    }
    return true;
}

/// Decodes the part of an A-label after `xn--` (RFC 3492 section 6.2).
fn decodePunycode(arena: std.mem.Allocator, input: []const u8) ![]const u21 {
    const base = 36;
    const tmin = 1;
    const tmax = 26;
    var output: std.ArrayList(u21) = .empty;
    var encoded = input;
    if (std.mem.lastIndexOfScalar(u8, input, '-')) |i| if (i > 0) {
        for (input[0..i]) |c| try output.append(arena, c);
        encoded = input[i + 1 ..];
    };

    var code_point: u32 = 128;
    var index: u32 = 0;
    var bias: u32 = 72;
    var position: usize = 0;
    while (position < encoded.len) {
        const previous = index;
        var weight: u32 = 1;
        var k: u32 = base;
        while (true) {
            if (position >= encoded.len) return error.Invalid;
            const c = encoded[position];
            position += 1;
            const digit: u32 = switch (c) {
                '0'...'9' => c - '0' + 26,
                'A'...'Z' => c - 'A',
                'a'...'z' => c - 'a',
                else => return error.Invalid,
            };
            index = try std.math.add(u32, index, try std.math.mul(u32, digit, weight));
            const threshold = if (k <= bias) tmin else if (k >= bias + tmax) tmax else k - bias;
            if (digit < threshold) break;
            weight = try std.math.mul(u32, weight, base - threshold);
            k += base;
        }
        const count: u32 = @intCast(output.items.len + 1);
        var delta = (index - previous) / @as(u32, if (previous == 0) 700 else 2);
        delta += delta / count;
        var bias_k: u32 = 0;
        while (delta > ((base - tmin) * tmax) / 2) : (bias_k += base) delta /= base - tmin;
        bias = bias_k + ((base - tmin + 1) * delta) / (delta + 38);
        code_point = try std.math.add(u32, code_point, index / count);
        index %= count;
        if (code_point > 0x10ffff or (code_point >= 0xd800 and code_point <= 0xdfff)) return error.Invalid;
        try output.insert(arena, index, @intCast(code_point));
        index += 1;
    }
    return output.items;
}

/// Matches the single code point `c` against `class`, a PCRE2 character class.
fn inClass(class: *const Regex, c: u21) bool {
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(c, &buffer) catch return false;
    return class.search(buffer[0..len]) catch false;
}

const virama = [_]u21{ 0x094D, 0x09CD, 0x0A4D, 0x0ACD, 0x0B4D, 0x0BCD, 0x0C4D, 0x0CCD, 0x0D4D, 0x0DCA, 0x0E3A, 0x0F84, 0x1039, 0x1714, 0x1734, 0x17D2, 0x1A60, 0x1B44, 0x1BAA, 0x1BF2, 0x1BF3, 0x2D7F, 0xA806, 0xA8C4, 0xA953, 0xABED, 0x10A3F, 0x11046, 0x1107F, 0x110B9, 0x11133, 0x111C0, 0x11235, 0x112EA, 0x1134D, 0x11442, 0x114C2, 0x115BF, 0x1163F, 0x116B6, 0x1172B, 0x11839, 0x119E0, 0x11A34, 0x11A47, 0x11A99, 0x11C3F, 0x11D44, 0x11D45, 0x11D97 };

/// Applies the RFC 5892 rules to a decoded label.
fn isIdnaLabel(label: []const u21) bool {
    var mark = Regex.compile("^\\p{M}$") catch return false;
    defer mark.deinit();
    var pvalid = Regex.compile("^[\\p{Lu}\\p{Ll}\\p{Lt}\\p{Lm}\\p{Lo}\\p{Mn}\\p{Mc}\\p{Nd}]$") catch return false;
    defer pvalid.deinit();
    if (label.len > 0 and inClass(&mark, label[0])) return false;
    var katakana_middle_dot = false;
    var hiragana_katakana_han = false;
    var arabic_indic = false;
    var extended_arabic_indic = false;
    for (label, 0..) |c, i| {
        const previous: ?u21 = if (i > 0) label[i - 1] else null;
        const next: ?u21 = if (i + 1 < label.len) label[i + 1] else null;
        switch (c) {
            0x200D => if (previous == null or std.mem.indexOfScalar(u21, &virama, previous.?) == null) return false,
            0x00B7 => if (previous != 'l' or next != 'l') return false,
            0x0375 => if (next == null or next.? < 0x0370 or next.? > 0x03FF) return false,
            0x05F3, 0x05F4 => if (previous == null or previous.? < 0x0590 or previous.? > 0x05FF) return false,
            0x30FB => katakana_middle_dot = true,
            0x3040...0x30FA, 0x30FC...0x30FF, 0x4E00...0x9FFF => hiragana_katakana_han = true,
            0x0660...0x0669 => arabic_indic = true,
            0x06F0...0x06F9 => extended_arabic_indic = true,
            0x0640, 0x07FA, 0x302E, 0x302F, 0x3031...0x3035, 0x303B => return false,
            0x200C, 0x06FD, 0x06FE, 0x0F0B, 0x3007 => {},
            else => if (c >= 0x80 and !inClass(&pvalid, c)) return false,
        }
    }
    return !(katakana_middle_dot and !hiragana_katakana_han) and !(arabic_indic and extended_arabic_indic);
}

fn isEmail(arena: std.mem.Allocator, s: []const u8) bool {
    const at = std.mem.lastIndexOfScalar(u8, s, '@') orelse return false;
    const local = s[0..at];
    const domain = s[at + 1 ..];
    if (local.len == 0 or local.len > 64 or domain.len == 0) return false;

    if (local.len >= 2 and local[0] == '"' and local[local.len - 1] == '"') {
        var i: usize = 1;
        while (i < local.len - 1) : (i += 1) {
            if (local[i] == '\\') {
                i += 1;
            } else if (local[i] == '"' or local[i] < 0x20) return false;
            if (local[i] >= 0x80) return false;
        }
    } else {
        if (local[0] == '.' or local[local.len - 1] == '.' or std.mem.indexOf(u8, local, "..") != null) return false;
        for (local) |c| {
            if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-/=?^_`{|}~.", c) == null) return false;
        }
    }

    if (domain[0] == '[' and domain[domain.len - 1] == ']') {
        const literal = domain[1 .. domain.len - 1];
        if (std.ascii.startsWithIgnoreCase(literal, "IPv6:")) return isIpv6(literal[5..]);
        return isIpv4(literal);
    }
    return isHostname(arena, domain, false);
}

fn isIpv4(s: []const u8) bool {
    var parts = std.mem.splitScalar(u8, s, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (part.len == 0 or part.len > 3 or (part.len > 1 and part[0] == '0')) return false;
        const n = digits(part) orelse return false;
        if (n > 255) return false;
    }
    return count == 4;
}

fn isIpv6(s: []const u8) bool {
    if (s.len < 2) return false;
    var groups: usize = 0;
    var compressed = false;
    var rest = s;
    if (std.mem.startsWith(u8, rest, "::")) {
        compressed = true;
        rest = rest[2..];
        if (rest.len == 0) return true;
    } else if (rest[0] == ':') return false;

    while (true) {
        const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const group = rest[0..end];
        if (end == rest.len and std.mem.indexOfScalar(u8, group, '.') != null) {
            if (!isIpv4(group)) return false;
            groups += 2;
            break;
        }
        if (group.len == 0 or group.len > 4) return false;
        for (group) |c| if (!std.ascii.isHex(c)) return false;
        groups += 1;
        if (end == rest.len) break;
        rest = rest[end + 1 ..];
        if (rest.len > 0 and rest[0] == ':') {
            if (compressed) return false;
            compressed = true;
            rest = rest[1..];
            if (rest.len == 0) break;
        } else if (rest.len == 0) return false;
    }
    return if (compressed) groups < 8 else groups == 8;
}

const UriOptions = struct { absolute: bool, unicode: bool };

/// Checks that every character of a URI component is allowed or percent-encoded.
fn validChars(s: []const u8, extra: []const u8, options: UriOptions) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%') {
            if (i + 2 >= s.len or !std.ascii.isHex(s[i + 1]) or !std.ascii.isHex(s[i + 2])) return false;
            i += 2;
        } else if (c >= 0x80) {
            if (!options.unicode) return false;
        } else if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=", c) == null and std.mem.indexOfScalar(u8, extra, c) == null) {
            return false;
        }
    }
    return true;
}

fn isUri(s: []const u8, options: UriOptions) bool {
    var rest = s;
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| {
        if (!validChars(rest[i + 1 ..], ":@/?", options)) return false;
        rest = rest[0..i];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
        if (!validChars(rest[i + 1 ..], ":@/?", options)) return false;
        rest = rest[0..i];
    }
    const colon = std.mem.indexOfScalar(u8, rest, ':');
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (colon != null and colon.? < slash) {
        const scheme = rest[0..colon.?];
        if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return false;
        for (scheme) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
        }
        rest = rest[colon.? + 1 ..];
    } else if (options.absolute) return false;

    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        var authority = rest[0..end];
        rest = rest[end..];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
            if (!validChars(authority[0..at], ":", options)) return false;
            authority = authority[at + 1 ..];
        }
        if (std.mem.startsWith(u8, authority, "[")) {
            const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
            if (!isIpv6(authority[1..close]) and !std.ascii.startsWithIgnoreCase(authority[1..close], "v")) return false;
            authority = authority[close + 1 ..];
            if (authority.len > 0 and authority[0] != ':') return false;
        }
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |i| {
            for (authority[i + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
            authority = authority[0..i];
        }
        if (!validChars(authority, "", options)) return false;
    }
    return validChars(rest, ":@/", options);
}

fn isJsonPointer(s: []const u8) bool {
    if (s.len > 0 and s[0] != '/') return false;
    for (s, 0..) |c, i| {
        if (c == '~' and (i + 1 >= s.len or (s[i + 1] != '0' and s[i + 1] != '1'))) return false;
    }
    return true;
}

fn isRelativeJsonPointer(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0 or (i > 1 and s[0] == '0')) return false;
    const rest = s[i..];
    return std.mem.eql(u8, rest, "#") or isJsonPointer(rest);
}

fn isRegex(s: []const u8) bool {
    var re = Regex.compile(s) catch |err| return err != error.InvalidPattern;
    re.deinit();
    return true;
}

fn isPercentEncoded(s: []const u8, i: usize) bool {
    return i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2]);
}

/// Checks RFC 6570 syntax.
fn isUriTemplate(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '{') {
            const end = std.mem.indexOfScalarPos(u8, s, i, '}') orelse return false;
            if (!isUriTemplateExpression(s[i + 1 .. end])) return false;
            i = end + 1;
        } else if (c == '%') {
            if (!isPercentEncoded(s, i)) return false;
            i += 3;
        } else {
            if (c <= ' ' or c == 0x7f or std.mem.indexOfScalar(u8, "\"<>\\^`|}", c) != null) return false;
            i += 1;
        }
    }
    return true;
}

fn isUriTemplateExpression(expression: []const u8) bool {
    var body = expression;
    if (body.len > 0 and std.mem.indexOfScalar(u8, "+#./;?&", body[0]) != null) body = body[1..];
    var specs = std.mem.splitScalar(u8, body, ',');
    while (specs.next()) |spec| {
        var name = spec;
        if (std.mem.endsWith(u8, name, "*")) {
            name = name[0 .. name.len - 1];
        } else if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
            const length = name[colon + 1 ..];
            if (length.len == 0 or length.len > 4 or length[0] == '0') return false;
            for (length) |d| if (!std.ascii.isDigit(d)) return false;
            name = name[0..colon];
        }
        if (name.len == 0 or name[0] == '.' or name[name.len - 1] == '.') return false;
        var i: usize = 0;
        while (i < name.len) {
            const c = name[i];
            if (c == '%') {
                if (!isPercentEncoded(name, i)) return false;
                i += 3;
                continue;
            }
            if (c == '.' and name[i + 1] == '.') return false;
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') return false;
            i += 1;
        }
    }
    return true;
}

test "dates and times" {
    try std.testing.expect(isDate("2020-02-29"));
    try std.testing.expect(!isDate("2021-02-29"));
    try std.testing.expect(!isDate("1998-1-20"));
    try std.testing.expect(isTime("08:30:06.283185Z"));
    try std.testing.expect(isTime("23:59:60Z"));
    try std.testing.expect(!isTime("22:59:60Z"));
    try std.testing.expect(isTime("15:59:60-08:00"));
    try std.testing.expect(!isTime("08:30:06"));
    try std.testing.expect(isDateTime("1963-06-19t08:30:06.283185z"));
}

test "network formats" {
    const arena = std.testing.allocator;
    try std.testing.expect(isEmail(arena, "joe.bloggs@example.com"));
    try std.testing.expect(!isEmail(arena, "joe..bloggs@example.com"));
    try std.testing.expect(isHostname(arena, "www.example.com", false));
    try std.testing.expect(!isHostname(arena, "-a-host-name-that-starts-with--", false));
    try std.testing.expect(!isHostname(arena, "example.com.", false));
    try std.testing.expect(isHostname(arena, "ab--cd", true));
    try std.testing.expect(!isHostname(arena, "ab--cd", false));
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    try std.testing.expect(isHostname(fba.allocator(), "xn--4gbwdl.xn--wgbh1c", false));
    try std.testing.expect(!isHostname(fba.allocator(), "xn--X", false));
    try std.testing.expect(isIpv4("192.168.0.1"));
    try std.testing.expect(!isIpv4("087.10.0.1"));
    try std.testing.expect(isIpv6("::ffff:192.168.0.1"));
    try std.testing.expect(!isIpv6("1:1:1:1:1:1:1:1:1"));
    try std.testing.expect(!isIpv6("1::1::1"));
}

test "uris and pointers" {
    try std.testing.expect(isUri("http://foo.bar/?baz=qux#quux", .{ .absolute = true, .unicode = false }));
    try std.testing.expect(!isUri("//foo.bar/?baz=qux#quux", .{ .absolute = true, .unicode = false }));
    try std.testing.expect(isUri("//foo.bar/?baz=qux#quux", .{ .absolute = false, .unicode = false }));
    try std.testing.expect(!isUri("http://example.com/a b", .{ .absolute = true, .unicode = false }));
    try std.testing.expect(isJsonPointer("/foo/bar~0/baz~1/%a"));
    try std.testing.expect(!isJsonPointer("/foo/bar~"));
    try std.testing.expect(isRelativeJsonPointer("0#"));
    try std.testing.expect(!isRelativeJsonPointer("01/a"));
    try std.testing.expect(isUriTemplate("http://example.com/dictionary/{term:1}/{term}"));
    try std.testing.expect(!isUriTemplate("http://example.com/dictionary/{term:1}/{term"));
    try std.testing.expect(!isUriTemplate("{}"));
    try std.testing.expect(!isUriTemplate("{var:1*}"));
    try std.testing.expect(!isUriTemplate("{a..b}"));
}
