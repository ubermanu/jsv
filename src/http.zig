//! A minimal HTTP/1.1 GET client. Unlike `std.http.Client`, it runs TLS
//! inside a proxy CONNECT tunnel, so HTTPS_PROXY works.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Certificate = std.crypto.Certificate;
const tls = std.crypto.tls;
const uri = @import("uri.zig");

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
};

const max_redirects = 5;

io: Io,
gpa: Allocator,
environ: *const std.process.Environ.Map,
bundle: ?Certificate.Bundle = null,
bundle_lock: Io.RwLock = .init,
now: Io.Timestamp = undefined,

const Client = @This();

pub fn deinit(self: *Client) void {
    if (self.bundle) |*b| b.deinit(self.gpa);
}

/// Fetches `url`, following redirects. The body is allocated with `arena`.
pub fn get(self: *Client, arena: Allocator, url: []const u8) !Response {
    var location = url;
    var redirects: usize = 0;
    while (true) {
        const response = try self.request(arena, location);
        const redirect = switch (response.status) {
            .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => true,
            else => false,
        };
        if (redirect and redirects < max_redirects) if (response.location) |next| {
            location = try uri.resolve(arena, location, next);
            redirects += 1;
            continue;
        };
        return .{ .status = response.status, .body = response.body };
    }
}

const Raw = struct {
    status: std.http.Status,
    location: ?[]const u8,
    body: []const u8,
};

fn request(self: *Client, arena: Allocator, url: []const u8) !Raw {
    const io = self.io;
    const target = try std.Uri.parse(url);
    const secure = if (std.ascii.eqlIgnoreCase(target.scheme, "https"))
        true
    else if (std.ascii.eqlIgnoreCase(target.scheme, "http"))
        false
    else
        return error.UnsupportedUriScheme;
    const host = (try target.getHostAlloc(arena)).bytes;
    const port = target.port orelse @as(u16, if (secure) 443 else 80);
    const authority = if (std.mem.indexOfScalar(u8, host, ':') != null)
        try std.fmt.allocPrint(arena, "[{s}]:{d}", .{ host, port })
    else
        try std.fmt.allocPrint(arena, "{s}:{d}", .{ host, port });
    const proxy = try self.proxyFor(arena, secure, host);

    const connect_host = if (proxy) |p| (try p.getHostAlloc(arena)).bytes else host;
    const connect_port = if (proxy) |p| p.port orelse 80 else port;
    const stream = try (try Io.net.HostName.init(connect_host)).connect(io, connect_port, .{ .mode = .stream });
    defer stream.close(io);

    const socket_read_buffer = try arena.alloc(u8, tls.Client.min_buffer_len);
    const socket_write_buffer = try arena.alloc(u8, tls.Client.min_buffer_len);
    var stream_reader = stream.reader(io, socket_read_buffer);
    var stream_writer = stream.writer(io, socket_write_buffer);
    var in: *Io.Reader = &stream_reader.interface;
    var out: *Io.Writer = &stream_writer.interface;

    if (proxy != null and secure) {
        try out.print("CONNECT {s} HTTP/1.1\r\nHost: {s}\r\n", .{ authority, authority });
        try writeProxyAuthorization(arena, out, proxy.?);
        try out.writeAll("\r\n");
        try out.flush();
        var tunnel: std.http.Reader = .{ .in = in, .interface = undefined, .state = .ready, .max_head_len = 16 * 1024 };
        const head = try std.http.Client.Response.Head.parse(try tunnel.receiveHead());
        if (head.status.class() != .success) return error.ProxyConnectFailed;
    }

    var tls_client: tls.Client = undefined;
    if (secure) {
        try self.loadBundle();
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        tls_client = try tls.Client.init(in, out, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{ .gpa = self.gpa, .io = io, .lock = &self.bundle_lock, .bundle = &self.bundle.? } },
            .read_buffer = try arena.alloc(u8, tls.Client.min_buffer_len + 16 * 1024),
            .write_buffer = try arena.alloc(u8, tls.Client.min_buffer_len),
            .entropy = &entropy,
            .realtime_now = self.now,
            .allow_truncation_attacks = true,
        });
        in = &tls_client.reader;
        out = &tls_client.writer;
    }

    if (proxy != null and !secure) {
        try out.print("GET {s} HTTP/1.1\r\n", .{std.mem.sliceTo(url, '#')});
        try writeProxyAuthorization(arena, out, proxy.?);
    } else {
        try out.print("GET {s} HTTP/1.1\r\n", .{requestTarget(url)});
    }
    try out.print("Host: {s}\r\nUser-Agent: jsv\r\nAccept: application/json, */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n", .{authority});
    try out.flush();
    if (secure) try stream_writer.interface.flush();

    var reader: std.http.Reader = .{ .in = in, .interface = undefined, .state = .ready, .max_head_len = 64 * 1024 };
    const head = try std.http.Client.Response.Head.parse(try reader.receiveHead());
    const location = if (head.location) |l| try arena.dupe(u8, l) else null;
    const status = head.status;
    const body_reader = reader.bodyReader(try arena.alloc(u8, 16 * 1024), head.transfer_encoding, head.content_length);
    const body = body_reader.allocRemaining(arena, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.body_err orelse error.ReadFailed,
        else => |e| return e,
    };
    return .{ .status = status, .location = location, .body = body };
}

fn loadBundle(self: *Client) !void {
    if (self.bundle != null) return;
    self.now = Io.Clock.real.now(self.io);
    var bundle: Certificate.Bundle = .empty;
    errdefer bundle.deinit(self.gpa);
    try bundle.rescan(self.gpa, self.io, self.now);
    self.bundle = bundle;
}

/// Returns the path, query and nothing else of an absolute URL.
fn requestTarget(url: []const u8) []const u8 {
    const without_fragment = std.mem.sliceTo(url, '#');
    const scheme_end = std.mem.indexOf(u8, without_fragment, "://") orelse return "/";
    const rest = without_fragment[scheme_end + 3 ..];
    const start = std.mem.indexOfAny(u8, rest, "/?") orelse return "/";
    return if (rest[start] == '/') rest[start..] else "/";
}

fn writeProxyAuthorization(arena: Allocator, out: *Io.Writer, proxy: std.Uri) !void {
    const user = proxy.user orelse return;
    const credentials = try std.fmt.allocPrint(arena, "{s}:{s}", .{
        try user.toRawMaybeAlloc(arena),
        if (proxy.password) |p| try p.toRawMaybeAlloc(arena) else "",
    });
    const encoder = std.base64.standard.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(credentials.len));
    try out.print("Proxy-Authorization: Basic {s}\r\n", .{encoder.encode(encoded, credentials)});
}

fn proxyFor(self: *Client, arena: Allocator, secure: bool, host: []const u8) !?std.Uri {
    const names: []const []const u8 = if (secure)
        &.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }
    else
        &.{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" };
    const value = for (names) |name| {
        if (self.environ.get(name)) |v| if (v.len > 0) break v;
    } else return null;
    const no_proxy = self.environ.get("no_proxy") orelse self.environ.get("NO_PROXY") orelse "";
    if (bypassesProxy(no_proxy, host)) return null;
    const text = if (std.mem.indexOf(u8, value, "://") == null) try std.fmt.allocPrint(arena, "http://{s}", .{value}) else value;
    return try std.Uri.parse(text);
}

fn bypassesProxy(no_proxy: []const u8, host: []const u8) bool {
    var entries = std.mem.tokenizeAny(u8, no_proxy, ", ");
    while (entries.next()) |raw| {
        if (std.mem.eql(u8, raw, "*")) return true;
        var entry = std.mem.trimStart(u8, raw, "*.");
        if (std.mem.indexOfScalar(u8, entry, '/')) |slash| {
            if (inCidr(host, entry[0..slash], entry[slash + 1 ..])) return true;
            continue;
        }
        if (std.mem.lastIndexOfScalar(u8, entry, ':')) |colon| {
            if (std.mem.indexOfScalar(u8, entry, ':') == colon) entry = entry[0..colon];
        }
        if (std.ascii.eqlIgnoreCase(host, entry)) return true;
        if (host.len > entry.len and host[host.len - entry.len - 1] == '.' and std.ascii.endsWithIgnoreCase(host, entry)) return true;
    }
    return false;
}

fn inCidr(host: []const u8, network: []const u8, bits_text: []const u8) bool {
    const address = parseIp4(host) orelse return false;
    const base = parseIp4(network) orelse return false;
    const bits = std.fmt.parseInt(u6, bits_text, 10) catch return false;
    if (bits > 32) return false;
    const mask: u32 = if (bits == 0) 0 else ~@as(u32, 0) << @intCast(32 - @as(u7, bits));
    return address & mask == base & mask;
}

fn parseIp4(text: []const u8) ?u32 {
    var parts = std.mem.splitScalar(u8, text, '.');
    var value: u32 = 0;
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        value = (value << 8) | (std.fmt.parseInt(u8, part, 10) catch return null);
    }
    return if (count == 4) value else null;
}

test "request target keeps the path and query" {
    try std.testing.expectEqualStrings("/a/b?c=d", requestTarget("https://example.com/a/b?c=d#e"));
    try std.testing.expectEqualStrings("/", requestTarget("https://example.com"));
}

test "no_proxy matches hosts, domains and networks" {
    const list = "localhost,.example.com,10.0.0.0/8,internal:8080";
    try std.testing.expect(bypassesProxy(list, "localhost"));
    try std.testing.expect(bypassesProxy(list, "api.example.com"));
    try std.testing.expect(bypassesProxy(list, "example.com"));
    try std.testing.expect(!bypassesProxy(list, "notexample.com"));
    try std.testing.expect(bypassesProxy(list, "10.1.2.3"));
    try std.testing.expect(!bypassesProxy(list, "11.1.2.3"));
    try std.testing.expect(bypassesProxy(list, "internal"));
    try std.testing.expect(bypassesProxy("*", "anything"));
}
