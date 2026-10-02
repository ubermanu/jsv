const std = @import("std");
const options = @import("options");

const io = std.testing.io;
const gpa = std.testing.allocator;

const Output = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Output) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn jsv(files: []const []const u8) !Output {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, options.jsv);
    try argv.appendSlice(gpa, files);
    const result = try std.process.run(gpa, io, .{ .argv = argv.items });
    return .{
        .code = switch (result.term) {
            .exited => |code| code,
            else => 255,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn fixture(comptime name: []const u8) []const u8 {
    return options.fixtures ++ "/" ++ name;
}

fn serveNotFound(server: *std.Io.net.Server) void {
    while (true) {
        const stream = server.accept(io) catch return;
        defer stream.close(io);
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        _ = reader.interface.peekGreedy(1) catch {};
        var write_buffer: [128]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        writer.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n") catch {};
        writer.interface.flush() catch {};
    }
}

test "schema with relative id is valid" {
    const output = try jsv(&.{fixture("data/rope.json")});
    defer output.deinit();
    try std.testing.expectEqual(0, output.code);
}

test "relative refs resolve next to the schema" {
    const output = try jsv(&.{fixture("data/shield.json")});
    defer output.deinit();
    try std.testing.expectEqual(0, output.code);
}

test "errors from referenced schemas are reported" {
    const output = try jsv(&.{fixture("data/overpriced-plate.json")});
    defer output.deinit();
    try std.testing.expectEqual(1, output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "/cost/gp") != null);
}

test "missing remote ref reports the status" {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    const thread = try std.Thread.spawn(.{}, serveNotFound, .{&server});
    thread.detach();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var schema_buffer: [128]u8 = undefined;
    const schema = try std.fmt.bufPrint(&schema_buffer, "{{ \"$ref\": \"http://127.0.0.1:{d}/dice.json\" }}", .{server.socket.address.getPort()});
    try tmp.dir.writeFile(io, .{ .sub_path = "schema.json", .data = schema });
    try tmp.dir.writeFile(io, .{ .sub_path = "data.json", .data = "{ \"$schema\": \"schema.json\" }" });

    const data = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/data.json", .{tmp.sub_path});
    defer gpa.free(data);
    const output = try jsv(&.{data});
    defer output.deinit();
    try std.testing.expectEqual(1, output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "404") != null);
}
