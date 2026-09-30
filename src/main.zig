const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const schema = @import("schema.zig");
const HttpClient = @import("http.zig");
const uri = @import("uri.zig");

const version = @import("build_options").version;

const usage =
    \\Validate JSON files against their $schema
    \\
    \\Usage: jsv <FILES>...
    \\
    \\Arguments:
    \\  <FILES>...  JSON files to validate
    \\
    \\Options:
    \\  -h, --help     Print help
    \\  -V, --version  Print version
    \\
;

const Fetcher = struct {
    io: Io,
    client: HttpClient,

    fn retrieve(context: *anyopaque, arena: Allocator, location: []const u8, message: *[]const u8) error{ RetrieveFailed, OutOfMemory }![]const u8 {
        const self: *Fetcher = @ptrCast(@alignCast(context));
        if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
            return self.http(arena, location, message);
        }
        if (std.mem.startsWith(u8, location, "file:")) {
            const path = try uri.toPath(arena, location);
            return Io.Dir.cwd().readFileAlloc(self.io, path, arena, .unlimited) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => {
                    message.* = try std.fmt.allocPrint(arena, "failed to read schema: {s}: {t}", .{ path, err });
                    return error.RetrieveFailed;
                },
            };
        }
        message.* = try std.fmt.allocPrint(arena, "unsupported schema location: {s}", .{location});
        return error.RetrieveFailed;
    }

    fn http(self: *Fetcher, arena: Allocator, location: []const u8, message: *[]const u8) error{ RetrieveFailed, OutOfMemory }![]const u8 {
        const response = self.client.get(arena, location) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                message.* = try std.fmt.allocPrint(arena, "failed to fetch schema: {s}: {t}", .{ location, err });
                return error.RetrieveFailed;
            },
        };
        if (response.status.class() != .success) {
            message.* = try std.fmt.allocPrint(arena, "schema fetch returned {d} {s}: {s}", .{ @intFromEnum(response.status), response.status.phrase() orelse "", location });
            return error.RetrieveFailed;
        }
        return response.body;
    }
};

fn schemaLocation(arena: Allocator, io: Io, schema_ref: []const u8, file: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(schema_ref)) return uri.fromPath(arena, schema_ref);
    const path = try Io.Dir.cwd().realPathFileAlloc(io, file, arena);
    return uri.resolve(arena, try uri.fromPath(arena, path), schema_ref);
}

const FileError = error{ Reported, OutOfMemory };

fn validateFile(arena: Allocator, io: Io, registry: *schema.Registry, path: []const u8, out: *Io.Writer, message: *[]const u8) FileError!bool {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            message.* = try std.fmt.allocPrint(arena, "failed to read file: {s}: {t}", .{ path, err });
            return error.Reported;
        },
    };
    var parse_message: []const u8 = "";
    const instance = schema.parse(arena, text, &parse_message) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => {
            message.* = try std.fmt.allocPrint(arena, "invalid JSON: {s}: {s}", .{ path, parse_message });
            return error.Reported;
        },
    };
    const schema_ref = switch (instance) {
        .object => |o| if (o.get("$schema")) |s| (if (s == .string) s.string else null) else null,
        else => null,
    } orelse {
        message.* = try std.fmt.allocPrint(arena, "{s}: no $schema field", .{path});
        return error.Reported;
    };

    const location = schemaLocation(arena, io, schema_ref, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            message.* = try std.fmt.allocPrint(arena, "invalid $schema: {s}: {t}", .{ schema_ref, err });
            return error.Reported;
        },
    };
    const compiled = registry.compile(location, .draft2020_12) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RetrieveFailed => {
            message.* = registry.message;
            return error.Reported;
        },
        error.SchemaError => {
            message.* = try std.fmt.allocPrint(arena, "failed to compile schema {s}: {s}", .{ location, registry.message });
            return error.Reported;
        },
    };

    var failures: std.ArrayList(schema.Failure) = .empty;
    const valid = registry.validate(arena, compiled, &instance, &failures) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RetrieveFailed => unreachable,
        error.SchemaError => {
            message.* = try std.fmt.allocPrint(arena, "{s}: {s}", .{ path, registry.message });
            return error.Reported;
        },
    };
    if (valid) {
        out.print("{s}: valid\n", .{path}) catch {};
    } else for (failures.items) |failure| {
        out.print("{s}: {s} (at {s})\n", .{ path, failure.message, failure.path }) catch {};
    }
    return valid;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = (try init.minimal.args.toSlice(arena))[1..];

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const out = &stdout.interface;
    const err_out = &stderr.interface;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            return out.flush();
        }
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            try out.print("jsv {s}\n", .{version});
            return out.flush();
        }
    }
    if (args.len == 0) {
        try err_out.writeAll("error: the following required arguments were not provided:\n  <FILES>...\n\n" ++ "Usage: jsv <FILES>...\n");
        try err_out.flush();
        std.process.exit(2);
    }

    var fetcher: Fetcher = .{ .io = io, .client = .{ .io = io, .gpa = init.gpa, .environ = init.environ_map } };
    defer fetcher.client.deinit();
    var registry = schema.Registry.init(arena, .{ .context = &fetcher, .retrieveFn = Fetcher.retrieve });
    var all_valid = true;

    for (args) |path| {
        var file_arena = std.heap.ArenaAllocator.init(init.gpa);
        defer file_arena.deinit();
        var message: []const u8 = "";
        const valid = validateFile(file_arena.allocator(), io, &registry, path, out, &message) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Reported => blk: {
                try out.flush();
                try err_out.print("error: {s}\n", .{message});
                try err_out.flush();
                break :blk false;
            },
        };
        if (!valid) all_valid = false;
    }

    try out.flush();
    std.process.exit(if (all_valid) 0 else 1);
}

test {
    _ = schema;
    _ = uri;
    _ = HttpClient;
}
