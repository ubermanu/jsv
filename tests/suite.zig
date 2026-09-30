//! Runs the JSON-Schema-Test-Suite (https://github.com/json-schema-org/JSON-Schema-Test-Suite).
//! Usage: suite <path to the suite checkout>

const std = @import("std");
const schema = @import("schema");

const drafts = [_]struct { dir: []const u8, draft: schema.Draft }{
    .{ .dir = "draft4", .draft = .draft4 },
    .{ .dir = "draft6", .draft = .draft6 },
    .{ .dir = "draft7", .draft = .draft7 },
    .{ .dir = "draft2019-09", .draft = .draft2019_09 },
    .{ .dir = "draft2020-12", .draft = .draft2020_12 },
    .{ .dir = "draft4/optional/format", .draft = .draft4 },
    .{ .dir = "draft6/optional/format", .draft = .draft6 },
    .{ .dir = "draft7/optional/format", .draft = .draft7 },
};

/// Formats that the Rust version also leaves unchecked.
const skipped_files = [_][]const u8{ "idn-email.json", "idn-hostname.json" };

/// Required tests this implementation does not pass, as "draft/file: group".
const known_failures = [_][]const u8{
    "draft2019-09/vocabulary.json: schema that uses custom metaschema with with no validation vocabulary",
    "draft2020-12/vocabulary.json: schema that uses custom metaschema with with no validation vocabulary",
};

const Remotes = struct {
    io: std.Io,
    dir: []const u8,

    fn retrieve(context: *anyopaque, arena: std.mem.Allocator, location: []const u8, message: *[]const u8) error{ RetrieveFailed, OutOfMemory }![]const u8 {
        const self: *Remotes = @ptrCast(@alignCast(context));
        const prefix = "http://localhost:1234/";
        if (!std.mem.startsWith(u8, location, prefix)) {
            message.* = "not a suite remote";
            return error.RetrieveFailed;
        }
        const path = try std.fs.path.join(arena, &.{ self.dir, location[prefix.len..] });
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                message.* = @errorName(err);
                return error.RetrieveFailed;
            },
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: suite <JSON-Schema-Test-Suite path>\n", .{});
        std.process.exit(2);
    }
    const root = args[1];
    var remotes: Remotes = .{ .io = io, .dir = try std.fs.path.join(init.arena.allocator(), &.{ root, "remotes" }) };

    var passed: usize = 0;
    var failed: usize = 0;
    var unexpected: usize = 0;

    for (drafts) |d| {
        const dir_path = try std.fs.path.join(init.arena.allocator(), &.{ root, "tests", d.dir });
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);

        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            const skipped = for (skipped_files) |f| {
                if (std.mem.eql(u8, f, entry.name)) break true;
            } else false;
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json") and !skipped) {
                try names.append(init.arena.allocator(), try init.arena.allocator().dupe(u8, entry.name));
            }
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);

        for (names.items) |name| {
            var file_arena = std.heap.ArenaAllocator.init(gpa);
            defer file_arena.deinit();
            const fa = file_arena.allocator();
            const text = try dir.readFileAlloc(io, name, fa, .unlimited);
            var message: []const u8 = "";
            const groups = try schema.parse(fa, text, &message);

            for (groups.array.items) |group| {
                const description = group.object.get("description").?.string;
                const label = try std.fmt.allocPrint(fa, "{s}/{s}: {s}", .{ d.dir, name, description });
                const known = for (known_failures) |k| {
                    if (std.mem.eql(u8, k, label)) break true;
                } else false;

                var group_arena = std.heap.ArenaAllocator.init(gpa);
                defer group_arena.deinit();
                const ga = group_arena.allocator();
                var registry = schema.Registry.init(ga, .{ .context = &remotes, .retrieveFn = Remotes.retrieve });
                const location = compile(&registry, group.object.get("schema").?, d.draft) catch |err| {
                    const count = group.object.get("tests").?.array.items.len;
                    if (known) {
                        passed += count;
                        continue;
                    }
                    std.debug.print("FAIL {s}: {t} {s}\n", .{ label, err, registry.message });
                    failed += count;
                    unexpected += 1;
                    continue;
                };

                var group_failed = false;
                for (group.object.get("tests").?.array.items) |t| {
                    const expected = t.object.get("valid").?.bool;
                    const data = t.object.getPtr("data").?;
                    const actual = registry.validate(ga, location, data, null) catch |err| blk: {
                        std.debug.print("  error {s}: {t} {s}\n", .{ label, err, registry.message });
                        break :blk !expected;
                    };
                    if (actual == expected) {
                        passed += 1;
                    } else {
                        failed += 1;
                        group_failed = true;
                        if (!known) std.debug.print("FAIL {s} / {s}: expected {}\n", .{ label, t.object.get("description").?.string, expected });
                    }
                }
                if (group_failed and !known) unexpected += 1;
                if (!group_failed and known) std.debug.print("known failure now passes: {s}\n", .{label});
            }
        }
    }

    std.debug.print("{d} passed, {d} failed\n", .{ passed, failed });
    if (unexpected > 0) std.process.exit(1);
}

fn compile(registry: *schema.Registry, document: std.json.Value, draft: schema.Draft) !schema.Location {
    try registry.add("urn:jsv:suite", document, draft);
    return registry.compile("urn:jsv:suite", draft);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
