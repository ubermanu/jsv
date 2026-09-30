//! JSON Schema validation for drafts 4, 6, 7, 2019-09 and 2020-12.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Regex = @import("regex.zig");
const formats = @import("format.zig");
const uri = @import("uri.zig");

pub const Draft = enum {
    draft4,
    draft6,
    draft7,
    draft2019_09,
    draft2020_12,

    fn atLeast(d: Draft, other: Draft) bool {
        return @intFromEnum(d) >= @intFromEnum(other);
    }

    fn metaschema(d: Draft) []const u8 {
        return switch (d) {
            .draft4 => "http://json-schema.org/draft-04/schema",
            .draft6 => "http://json-schema.org/draft-06/schema",
            .draft7 => "http://json-schema.org/draft-07/schema",
            .draft2019_09 => "https://json-schema.org/draft/2019-09/schema",
            .draft2020_12 => "https://json-schema.org/draft/2020-12/schema",
        };
    }

    fn fromMetaschema(text: []const u8) ?Draft {
        var s = std.mem.trimEnd(u8, text, "#");
        inline for (.{ "https://", "http://" }) |prefix| {
            if (std.mem.startsWith(u8, s, prefix)) s = s[prefix.len..];
        }
        const map = std.StaticStringMap(Draft).initComptime(.{
            .{ "json-schema.org/draft-04/schema", .draft4 },
            .{ "json-schema.org/draft-06/schema", .draft6 },
            .{ "json-schema.org/draft-07/schema", .draft7 },
            .{ "json-schema.org/draft/2019-09/schema", .draft2019_09 },
            .{ "json-schema.org/draft/2020-12/schema", .draft2020_12 },
        });
        return map.get(s);
    }
};

const embedded = std.StaticStringMap([]const u8).initComptime(.{
    .{ "json-schema.org/draft-04/schema", @embedFile("metaschemas/draft-04.json") },
    .{ "json-schema.org/draft-06/schema", @embedFile("metaschemas/draft-06.json") },
    .{ "json-schema.org/draft-07/schema", @embedFile("metaschemas/draft-07.json") },
    .{ "json-schema.org/draft/2019-09/schema", @embedFile("metaschemas/2019-09-schema.json") },
    .{ "json-schema.org/draft/2019-09/meta/core", @embedFile("metaschemas/2019-09-core.json") },
    .{ "json-schema.org/draft/2019-09/meta/applicator", @embedFile("metaschemas/2019-09-applicator.json") },
    .{ "json-schema.org/draft/2019-09/meta/validation", @embedFile("metaschemas/2019-09-validation.json") },
    .{ "json-schema.org/draft/2019-09/meta/meta-data", @embedFile("metaschemas/2019-09-meta-data.json") },
    .{ "json-schema.org/draft/2019-09/meta/format", @embedFile("metaschemas/2019-09-format.json") },
    .{ "json-schema.org/draft/2019-09/meta/content", @embedFile("metaschemas/2019-09-content.json") },
    .{ "json-schema.org/draft/2020-12/schema", @embedFile("metaschemas/2020-12-schema.json") },
    .{ "json-schema.org/draft/2020-12/meta/core", @embedFile("metaschemas/2020-12-core.json") },
    .{ "json-schema.org/draft/2020-12/meta/applicator", @embedFile("metaschemas/2020-12-applicator.json") },
    .{ "json-schema.org/draft/2020-12/meta/unevaluated", @embedFile("metaschemas/2020-12-unevaluated.json") },
    .{ "json-schema.org/draft/2020-12/meta/validation", @embedFile("metaschemas/2020-12-validation.json") },
    .{ "json-schema.org/draft/2020-12/meta/meta-data", @embedFile("metaschemas/2020-12-meta-data.json") },
    .{ "json-schema.org/draft/2020-12/meta/format-annotation", @embedFile("metaschemas/2020-12-format-annotation.json") },
    .{ "json-schema.org/draft/2020-12/meta/content", @embedFile("metaschemas/2020-12-content.json") },
});

fn embeddedDocument(location: []const u8) ?[]const u8 {
    inline for (.{ "https://", "http://" }) |prefix| {
        if (std.mem.startsWith(u8, location, prefix)) return embedded.get(location[prefix.len..]);
    }
    return null;
}

pub const Error = error{ SchemaError, RetrieveFailed, OutOfMemory };

/// Parses JSON. On a syntax error, `message` describes it with its position.
pub fn parse(arena: Allocator, text: []const u8, message: *[]const u8) error{ InvalidJson, OutOfMemory }!Value {
    var scanner = std.json.Scanner.initCompleteInput(arena, text);
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);
    return std.json.parseFromTokenSourceLeaky(Value, arena, &scanner, .{ .duplicate_field_behavior = .use_last }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            message.* = try std.fmt.allocPrint(arena, "{t} at line {d} column {d}", .{ err, diagnostics.getLine(), diagnostics.getColumn() });
            return error.InvalidJson;
        },
    };
}

/// Fetches the JSON text of a schema document. On failure, sets `message`.
pub const Retriever = struct {
    context: *anyopaque,
    retrieveFn: *const fn (context: *anyopaque, arena: Allocator, location: []const u8, message: *[]const u8) error{ RetrieveFailed, OutOfMemory }![]const u8,
};

const Resource = struct {
    uri: []const u8,
    root: *const Value,
    draft: Draft,
};

pub const Location = struct {
    schema: *const Value,
    resource: *Resource,
};

pub const Failure = struct {
    message: []const u8,
    path: []const u8,
};

const PendingRef = struct { ref: []const u8, resource: *Resource };

const RefKey = struct { ref: *const Value, resource: *Resource };

pub const Registry = struct {
    arena: Allocator,
    retriever: Retriever,
    /// Diagnostic for the last `error.SchemaError`.
    message: []const u8 = "",
    resources: std.StringHashMapUnmanaged(*Resource) = .empty,
    resource_of: std.AutoHashMapUnmanaged(*const Value, *Resource) = .empty,
    anchors: std.StringHashMapUnmanaged(Location) = .empty,
    dynamic_anchors: std.StringHashMapUnmanaged(void) = .empty,
    regexes: std.StringHashMapUnmanaged(Regex) = .empty,
    refs: std.AutoHashMapUnmanaged(RefKey, Location) = .empty,
    checked: std.StringHashMapUnmanaged(void) = .empty,
    pending: std.ArrayList(PendingRef) = .empty,

    pub fn init(arena: Allocator, retriever: Retriever) Registry {
        return .{ .arena = arena, .retriever = retriever };
    }

    fn fail(self: *Registry, comptime format: []const u8, args: anytype) Error {
        self.message = std.fmt.allocPrint(self.arena, format, args) catch return error.OutOfMemory;
        return error.SchemaError;
    }

    /// Registers a parsed document under `location` without retrieving it.
    pub fn add(self: *Registry, location: []const u8, document: Value, default_draft: Draft) Error!void {
        const root = try self.arena.create(Value);
        root.* = document;
        _ = try self.register(try self.arena.dupe(u8, location), root, default_draft);
    }

    /// Loads the schema at `location`, resolves every reference it makes and
    /// checks it against its meta-schema. Returns `error.RetrieveFailed` when
    /// the schema itself cannot be loaded.
    pub fn compile(self: *Registry, location: []const u8, default_draft: Draft) Error!Location {
        const doc, _ = uri.splitFragment(location);
        const resource = self.load(doc, default_draft) catch |err| return switch (err) {
            error.SchemaError => error.RetrieveFailed,
            else => err,
        };
        try self.resolvePending();
        const target = try self.resolve(resource, location);

        const key = try self.arena.dupe(u8, doc);
        if (!(try self.checked.getOrPut(self.arena, key)).found_existing) {
            try self.checkMetaschema(target.resource);
        }
        return target;
    }

    fn checkMetaschema(self: *Registry, resource: *Resource) Error!void {
        const meta_uri = if (schemaKeyword(resource.root.*)) |s|
            (if (Draft.fromMetaschema(s) != null) s else return)
        else
            resource.draft.metaschema();
        const meta_doc, _ = uri.splitFragment(meta_uri);
        const meta_resource = try self.load(meta_doc, resource.draft);
        try self.resolvePending();
        const meta: Location = .{ .schema = meta_resource.root, .resource = self.resource_of.get(meta_resource.root) orelse meta_resource };

        var arena_state = std.heap.ArenaAllocator.init(self.arena);
        defer arena_state.deinit();
        var failures: std.ArrayList(Failure) = .empty;
        if (!try self.validate(arena_state.allocator(), meta, resource.root, &failures)) {
            const first = failures.items[0];
            return self.fail("invalid schema: {s} (at {s})", .{ first.message, first.path });
        }
    }

    fn load(self: *Registry, doc: []const u8, default_draft: Draft) Error!*Resource {
        if (self.resources.get(doc)) |resource| return resource;
        const text = embeddedDocument(doc) orelse blk: {
            var message: []const u8 = "";
            break :blk self.retriever.retrieveFn(self.retriever.context, self.arena, doc, &message) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.RetrieveFailed => {
                    self.message = message;
                    return error.SchemaError;
                },
            };
        };
        const root = try self.arena.create(Value);
        var message: []const u8 = "";
        root.* = parse(self.arena, text, &message) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => return self.fail("failed to parse schema JSON from {s}: {s}", .{ doc, message }),
        };
        return self.register(try self.arena.dupe(u8, doc), root, default_draft);
    }

    fn register(self: *Registry, location: []const u8, root: *const Value, default_draft: Draft) Error!*Resource {
        const draft = if (schemaKeyword(root.*)) |s| Draft.fromMetaschema(s) orelse default_draft else default_draft;
        const resource = try self.arena.create(Resource);
        resource.* = .{ .uri = location, .root = root, .draft = draft };
        try self.resources.put(self.arena, location, resource);
        try self.walk(root, resource, true);
        return resource;
    }

    /// Records identifiers, anchors, references and patterns of a schema and its subschemas.
    fn walk(self: *Registry, schema: *const Value, parent: *Resource, is_root: bool) Error!void {
        const object = switch (schema.*) {
            .object => |*o| o,
            else => return,
        };
        var resource = parent;
        const draft = parent.draft;
        const has_ref = object.contains("$ref");
        const id_key = if (draft == .draft4) "id" else "$id";
        const ignores_id = has_ref and !draft.atLeast(.draft2019_09);

        if (stringField(object, id_key)) |id| if (!ignores_id) {
            const resolved = try uri.resolve(self.arena, parent.uri, id);
            const doc, const fragment = uri.splitFragment(resolved);
            if (!std.mem.startsWith(u8, id, "#")) {
                const child_draft = if (schemaKeyword(schema.*)) |s| Draft.fromMetaschema(s) orelse draft else draft;
                resource = try self.arena.create(Resource);
                resource.* = .{ .uri = doc, .root = schema, .draft = child_draft };
                try self.resources.put(self.arena, doc, resource);
                try self.resource_of.put(self.arena, schema, resource);
            }
            if (fragment.len > 0 and !draft.atLeast(.draft2019_09)) {
                try self.addAnchor(resource, fragment, schema, false);
            }
        };
        if (is_root and !self.resource_of.contains(schema)) try self.resource_of.put(self.arena, schema, resource);

        if (resource.draft.atLeast(.draft2019_09)) {
            if (stringField(object, "$anchor")) |name| try self.addAnchor(resource, name, schema, false);
        }
        if (resource.draft == .draft2020_12) {
            if (stringField(object, "$dynamicAnchor")) |name| try self.addAnchor(resource, name, schema, true);
            if (stringField(object, "$dynamicRef")) |ref| try self.pending.append(self.arena, .{ .ref = ref, .resource = resource });
        }
        if (stringField(object, "$ref")) |ref| try self.pending.append(self.arena, .{ .ref = ref, .resource = resource });

        if (stringField(object, "pattern")) |pattern| _ = try self.regex(pattern);
        if (object.getPtr("patternProperties")) |p| if (p.* == .object) {
            for (p.object.keys()) |pattern| _ = try self.regex(pattern);
        };

        const single = [_][]const u8{ "additionalItems", "additionalProperties", "contains", "not", "if", "then", "else", "propertyNames", "unevaluatedItems", "unevaluatedProperties", "items", "contentSchema" };
        const lists = [_][]const u8{ "allOf", "anyOf", "oneOf", "prefixItems", "items" };
        const maps = [_][]const u8{ "properties", "patternProperties", "definitions", "$defs", "dependencies", "dependentSchemas" };
        for (single) |key| if (object.getPtr(key)) |sub| try self.walk(sub, resource, false);
        for (lists) |key| if (object.getPtr(key)) |sub| if (sub.* == .array) {
            for (sub.array.items) |*item| try self.walk(item, resource, false);
        };
        for (maps) |key| if (object.getPtr(key)) |sub| if (sub.* == .object) {
            for (sub.object.values()) |*item| try self.walk(item, resource, false);
        };
    }

    fn addAnchor(self: *Registry, resource: *Resource, name: []const u8, schema: *const Value, dynamic: bool) Error!void {
        const key = try std.fmt.allocPrint(self.arena, "{s}#{s}", .{ resource.uri, name });
        try self.anchors.put(self.arena, key, .{ .schema = schema, .resource = resource });
        if (dynamic) try self.dynamic_anchors.put(self.arena, key, {});
    }

    fn regex(self: *Registry, pattern: []const u8) Error!*const Regex {
        const entry = try self.regexes.getOrPut(self.arena, pattern);
        if (!entry.found_existing) {
            entry.value_ptr.* = Regex.compile(self.arena, pattern) catch |err| {
                _ = self.regexes.remove(pattern);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidPattern => self.fail("invalid regular expression: {s}", .{pattern}),
                    error.UnsupportedPattern => self.fail("unsupported regular expression: {s}", .{pattern}),
                };
            };
        }
        return entry.value_ptr;
    }

    fn resolvePending(self: *Registry) Error!void {
        errdefer self.pending.clearRetainingCapacity();
        while (self.pending.pop()) |pending| {
            _ = try self.resolve(pending.resource, pending.ref);
        }
    }

    fn resolve(self: *Registry, base: *Resource, ref: []const u8) Error!Location {
        const absolute = try uri.resolve(self.arena, base.uri, ref);
        const doc, const fragment = uri.splitFragment(absolute);
        const resource = try self.load(doc, base.draft);
        const root: Location = .{ .schema = resource.root, .resource = self.resource_of.get(resource.root) orelse resource };
        if (fragment.len == 0) return root;
        if (fragment[0] != '/') {
            return self.anchors.get(absolute) orelse self.fail("unresolvable reference: {s}", .{absolute});
        }

        const pointer = try uri.percentDecode(self.arena, fragment);
        var location = root;
        var tokens = std.mem.splitScalar(u8, pointer[1..], '/');
        while (tokens.next()) |raw| {
            const token = try unescapePointer(self.arena, raw);
            const next: ?*const Value = switch (location.schema.*) {
                .object => |*o| o.getPtr(token),
                .array => |*a| blk: {
                    const index = std.fmt.parseInt(usize, token, 10) catch break :blk null;
                    break :blk if (index < a.items.len) &a.items[index] else null;
                },
                else => null,
            };
            location.schema = next orelse return self.fail("unresolvable reference: {s}", .{absolute});
            if (self.resource_of.get(location.schema)) |r| location.resource = r;
        }
        return location;
    }

    fn resolveCached(self: *Registry, base: *Resource, ref: *const Value) Error!Location {
        const entry = try self.refs.getOrPut(self.arena, .{ .ref = ref, .resource = base });
        if (!entry.found_existing) {
            entry.value_ptr.* = self.resolve(base, ref.string) catch |err| {
                _ = self.refs.remove(.{ .ref = ref, .resource = base });
                return err;
            };
            try self.resolvePending();
        }
        return entry.value_ptr.*;
    }

    /// Validates `instance`. Collects failures when `failures` is given,
    /// allocating them and all scratch data with `arena`.
    pub fn validate(self: *Registry, arena: Allocator, schema: Location, instance: *const Value, failures: ?*std.ArrayList(Failure)) Error!bool {
        var validator: Validator = .{ .registry = self, .arena = arena, .failures = failures };
        try validator.scope.append(arena, schema.resource);
        return validator.check(schema.schema, schema.resource, instance, failures != null, null);
    }
};

fn schemaKeyword(schema: Value) ?[]const u8 {
    return switch (schema) {
        .object => |*o| stringField(o, "$schema"),
        else => null,
    };
}

fn stringField(object: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn unescapePointer(arena: Allocator, token: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, token, '~') == null) return token;
    const once = try std.mem.replaceOwned(u8, arena, token, "~1", "/");
    return std.mem.replaceOwned(u8, arena, once, "~0", "~");
}

const Segment = union(enum) { key: []const u8, index: usize };

/// Marks which properties or items of an instance some subschema evaluated.
const Evaluated = std.DynamicBitSetUnmanaged;

const max_depth = 512;

const Validator = struct {
    registry: *Registry,
    arena: Allocator,
    failures: ?*std.ArrayList(Failure),
    scope: std.ArrayList(*Resource) = .empty,
    path: std.ArrayList(Segment) = .empty,
    depth: usize = 0,

    fn report(v: *Validator, comptime format: []const u8, args: anytype) Error!void {
        const failures = v.failures orelse return;
        var pointer: std.Io.Writer.Allocating = .init(v.arena);
        for (v.path.items) |segment| switch (segment) {
            .index => |i| pointer.writer.print("/{d}", .{i}) catch return error.OutOfMemory,
            .key => |key| {
                pointer.writer.writeByte('/') catch return error.OutOfMemory;
                for (key) |c| switch (c) {
                    '~' => pointer.writer.writeAll("~0") catch return error.OutOfMemory,
                    '/' => pointer.writer.writeAll("~1") catch return error.OutOfMemory,
                    else => pointer.writer.writeByte(c) catch return error.OutOfMemory,
                };
            },
        };
        try failures.append(v.arena, .{
            .message = try std.fmt.allocPrint(v.arena, format, args),
            .path = pointer.written(),
        });
    }

    fn json(v: *Validator, value: anytype) Error![]const u8 {
        return std.json.Stringify.valueAlloc(v.arena, value, .{});
    }

    /// Validates `instance` against `schema`. When valid, merges the
    /// properties or items it evaluated into `evaluated`.
    fn check(v: *Validator, schema: *const Value, parent: *Resource, instance: *const Value, collect: bool, evaluated: ?*Evaluated) Error!bool {
        switch (schema.*) {
            .bool => |allowed| {
                if (!allowed and collect) try v.report("False schema does not allow {s}", .{try v.json(instance.*)});
                return allowed;
            },
            .object => {},
            else => return true,
        }
        const object = &schema.object;

        if (v.depth >= max_depth) return v.registry.fail("schema recursion is too deep", .{});
        v.depth += 1;
        defer v.depth -= 1;

        var resource = parent;
        const scope_len = v.scope.items.len;
        defer v.scope.shrinkRetainingCapacity(scope_len);
        if (v.registry.resource_of.get(schema)) |r| {
            resource = r;
            try v.scope.append(v.arena, r);
        }
        const draft = resource.draft;

        const size: usize = switch (instance.*) {
            .object => |o| o.count(),
            .array => |a| a.items.len,
            else => 0,
        };
        var local = try Evaluated.initEmpty(v.arena, size);
        var kw: Keywords = .{ .v = v, .object = object, .resource = resource, .draft = draft, .instance = instance, .collect = collect, .local = &local };

        const ref_only = !draft.atLeast(.draft2019_09) and object.contains("$ref");
        const valid = if (ref_only) try kw.ref(object.getPtr("$ref").?) else try kw.all();

        if (valid) if (evaluated) |e| e.setUnion(local);
        return valid;
    }

    fn checkChild(v: *Validator, schema: *const Value, resource: *Resource, instance: *const Value, segment: Segment, collect: bool) Error!bool {
        try v.path.append(v.arena, segment);
        defer _ = v.path.pop();
        return v.check(schema, resource, instance, collect, null);
    }
};

const Keywords = struct {
    v: *Validator,
    object: *const std.json.ObjectMap,
    resource: *Resource,
    draft: Draft,
    instance: *const Value,
    collect: bool,
    local: *Evaluated,
    valid: bool = true,

    fn get(k: *Keywords, key: []const u8) ?*const Value {
        return k.object.getPtr(key);
    }

    /// Records a failed keyword. Returns true when validation may stop early.
    fn failed(k: *Keywords) bool {
        k.valid = false;
        return !k.collect;
    }

    fn report(k: *Keywords, comptime format: []const u8, args: anytype) Error!bool {
        if (k.collect) try k.v.report(format, args);
        return k.failed();
    }

    fn inPlace(k: *Keywords, schema: *const Value, collect: bool) Error!bool {
        return k.v.check(schema, k.resource, k.instance, collect, k.local);
    }

    fn follow(k: *Keywords, target: Location) Error!bool {
        const scope_len = k.v.scope.items.len;
        defer k.v.scope.shrinkRetainingCapacity(scope_len);
        try k.v.scope.append(k.v.arena, target.resource);
        return k.v.check(target.schema, target.resource, k.instance, k.collect, k.local);
    }

    fn ref(k: *Keywords, value: *const Value) Error!bool {
        if (value.* != .string) return true;
        const target = try k.v.registry.resolveCached(k.resource, value);
        if (!try k.follow(target)) _ = k.failed();
        return k.valid;
    }

    fn all(k: *Keywords) Error!bool {
        const steps = .{ refs, applicators, conditionals, validations, objects, arrays, unevaluated };
        inline for (steps) |step| {
            if (try step(k)) return false;
        }
        return k.valid;
    }

    fn refs(k: *Keywords) Error!bool {
        if (k.get("$ref")) |value| {
            if (!try k.ref(value) and !k.collect) return true;
        }
        if (k.draft == .draft2019_09) if (k.get("$recursiveRef")) |value| if (value.* == .string) {
            var target = try k.v.registry.resolve(k.resource, "#");
            if (isTrue(target.schema, "$recursiveAnchor")) {
                var i = k.v.scope.items.len;
                while (i > 0) {
                    i -= 1;
                    const r = k.v.scope.items[i];
                    if (!isTrue(r.root, "$recursiveAnchor")) break;
                    target = .{ .schema = r.root, .resource = r };
                }
            }
            if (!try k.follow(target) and k.failed()) return true;
        };
        if (k.draft == .draft2020_12) if (k.get("$dynamicRef")) |value| if (value.* == .string) {
            var target = try k.v.registry.resolveCached(k.resource, value);
            _, const fragment = uri.splitFragment(value.string);
            const bookend = target.schema.* == .object and
                std.mem.eql(u8, stringField(&target.schema.object, "$dynamicAnchor") orelse "", fragment);
            if (fragment.len > 0 and fragment[0] != '/' and bookend) {
                for (k.v.scope.items) |r| {
                    const key = try std.fmt.allocPrint(k.v.arena, "{s}#{s}", .{ r.uri, fragment });
                    if (k.v.registry.dynamic_anchors.contains(key)) {
                        target = k.v.registry.anchors.get(key).?;
                        break;
                    }
                }
            }
            if (!try k.follow(target) and k.failed()) return true;
        };
        return false;
    }

    fn applicators(k: *Keywords) Error!bool {
        if (k.get("allOf")) |list| if (list.* == .array) {
            for (list.array.items) |*sub| {
                if (!try k.inPlace(sub, k.collect) and k.failed()) return true;
            }
        };
        if (k.get("anyOf")) |list| if (list.* == .array) {
            var any = false;
            for (list.array.items) |*sub| {
                if (try k.inPlace(sub, false)) any = true;
            }
            if (!any and try k.report("{s} is not valid under any of the schemas listed in the 'anyOf' keyword", .{try k.v.json(k.instance.*)})) return true;
        };
        if (k.get("oneOf")) |list| if (list.* == .array) {
            var matches: usize = 0;
            var branch = try Evaluated.initEmpty(k.v.arena, k.local.bit_length);
            for (list.array.items) |*sub| {
                if (try k.v.check(sub, k.resource, k.instance, false, &branch)) matches += 1;
            }
            if (matches == 1) {
                k.local.setUnion(branch);
            } else if (matches == 0) {
                if (try k.report("{s} is not valid under any of the schemas listed in the 'oneOf' keyword", .{try k.v.json(k.instance.*)})) return true;
            } else {
                if (try k.report("{s} is valid under more than one of the schemas listed in the 'oneOf' keyword", .{try k.v.json(k.instance.*)})) return true;
            }
        };
        if (k.get("not")) |sub| {
            if (try k.v.check(sub, k.resource, k.instance, false, null)) {
                if (try k.report("{s} should not be valid under {s}", .{ try k.v.json(k.instance.*), try k.v.json(sub.*) })) return true;
            }
        }
        return false;
    }

    fn conditionals(k: *Keywords) Error!bool {
        if (!k.draft.atLeast(.draft7)) return false;
        const condition = k.get("if") orelse return false;
        const branch = if (try k.inPlace(condition, false)) k.get("then") else k.get("else");
        if (branch) |sub| {
            if (!try k.inPlace(sub, k.collect) and k.failed()) return true;
        }
        return false;
    }

    fn validations(k: *Keywords) Error!bool {
        const v = k.v;
        const instance = k.instance.*;
        if (k.get("type")) |types| {
            const ok = switch (types.*) {
                .string => |name| isType(instance, name, k.draft),
                .array => |list| for (list.items) |t| {
                    if (t == .string and isType(instance, t.string, k.draft)) break true;
                } else false,
                else => true,
            };
            if (!ok) {
                const joined = if (types.* == .array) try joinTypes(v.arena, types.array.items) else try v.json(types.*);
                const noun = if (types.* == .array) "types" else "type";
                if (try k.report("{s} is not of {s} {s}", .{ try v.json(instance), noun, joined })) return true;
            }
        }
        if (k.get("enum")) |options| if (options.* == .array) {
            for (options.array.items) |option| {
                if (equal(option, instance)) break;
            } else if (try k.report("{s} is not one of {s}", .{ try v.json(instance), try v.json(options.*) })) return true;
        };
        if (k.draft.atLeast(.draft6)) if (k.get("const")) |expected| {
            if (!equal(expected.*, instance) and try k.report("{s} was expected", .{try v.json(expected.*)})) return true;
        };

        if (number(instance)) |n| {
            if (try k.numbers(n)) return true;
        }

        if (instance == .string) {
            const length = std.unicode.utf8CountCodepoints(instance.string) catch instance.string.len;
            if (limit(k.get("minLength"))) |min| if (length < min) {
                if (try k.report("{s} is shorter than {d} character{s}", .{ try v.json(instance), min, plural(min) })) return true;
            };
            if (limit(k.get("maxLength"))) |max| if (length > max) {
                if (try k.report("{s} is longer than {d} character{s}", .{ try v.json(instance), max, plural(max) })) return true;
            };
            if (k.get("pattern")) |pattern| if (pattern.* == .string) {
                const re = try v.registry.regex(pattern.string);
                if (!try re.search(v.arena, instance.string)) {
                    if (try k.report("{s} does not match {s}", .{ try v.json(instance), try v.json(pattern.*) })) return true;
                }
            };
            if (!k.draft.atLeast(.draft2019_09)) if (k.get("format")) |name| if (name.* == .string) {
                if (formats.check(v.arena, name.string, instance.string, k.draft != .draft7) == false) {
                    if (try k.report("{s} is not a {s}", .{ try v.json(instance), try v.json(name.*) })) return true;
                }
            };
        }
        return false;
    }

    fn numbers(k: *Keywords, n: f64) Error!bool {
        const v = k.v;
        const shown = try v.json(k.instance.*);
        if (k.get("multipleOf")) |divisor| if (number(divisor.*)) |d| {
            if (!isMultiple(k.instance.*, divisor.*, n, d)) {
                if (try k.report("{s} is not a multiple of {s}", .{ shown, try v.json(divisor.*) })) return true;
            }
        };
        const exclusive_max_flag = k.draft == .draft4 and isTrue(k.object, "exclusiveMaximum");
        const exclusive_min_flag = k.draft == .draft4 and isTrue(k.object, "exclusiveMinimum");
        if (k.get("maximum")) |bound| if (number(bound.*)) |max| {
            if (exclusive_max_flag and n >= max) {
                if (try k.report("{s} is greater than or equal to the maximum of {s}", .{ shown, try v.json(bound.*) })) return true;
            } else if (n > max) {
                if (try k.report("{s} is greater than the maximum of {s}", .{ shown, try v.json(bound.*) })) return true;
            }
        };
        if (k.get("minimum")) |bound| if (number(bound.*)) |min| {
            if (exclusive_min_flag and n <= min) {
                if (try k.report("{s} is less than or equal to the minimum of {s}", .{ shown, try v.json(bound.*) })) return true;
            } else if (n < min) {
                if (try k.report("{s} is less than the minimum of {s}", .{ shown, try v.json(bound.*) })) return true;
            }
        };
        if (k.draft.atLeast(.draft6)) {
            if (k.get("exclusiveMaximum")) |bound| if (number(bound.*)) |max| if (n >= max) {
                if (try k.report("{s} is greater than or equal to the maximum of {s}", .{ shown, try v.json(bound.*) })) return true;
            };
            if (k.get("exclusiveMinimum")) |bound| if (number(bound.*)) |min| if (n <= min) {
                if (try k.report("{s} is less than or equal to the minimum of {s}", .{ shown, try v.json(bound.*) })) return true;
            };
        }
        return false;
    }

    fn objects(k: *Keywords) Error!bool {
        const instance = switch (k.instance.*) {
            .object => |*o| o,
            else => return false,
        };
        const v = k.v;
        const keys = instance.keys();
        const values = instance.values();

        if (limit(k.get("minProperties"))) |min| if (keys.len < min) {
            if (try k.report("{s} has less than {d} propert{s}", .{ try v.json(k.instance.*), min, if (min == 1) "y" else "ies" })) return true;
        };
        if (limit(k.get("maxProperties"))) |max| if (keys.len > max) {
            if (try k.report("{s} has more than {d} propert{s}", .{ try v.json(k.instance.*), max, if (max == 1) "y" else "ies" })) return true;
        };
        if (k.get("required")) |required| if (required.* == .array) {
            for (required.array.items) |name| {
                if (name == .string and !instance.contains(name.string)) {
                    if (try k.report("{s} is a required property", .{try v.json(name)})) return true;
                }
            }
        };

        if (k.get("dependentRequired")) |deps| if (deps.* == .object and k.draft.atLeast(.draft2019_09)) {
            if (try k.dependentRequired(&deps.object)) return true;
        };
        if (k.get("dependentSchemas")) |deps| if (deps.* == .object and k.draft.atLeast(.draft2019_09)) {
            for (deps.object.keys(), deps.object.values()) |name, *sub| {
                if (instance.contains(name) and !try k.inPlace(sub, k.collect) and k.failed()) return true;
            }
        };
        if (k.get("dependencies")) |deps| if (deps.* == .object) {
            if (try k.dependentRequired(&deps.object)) return true;
            for (deps.object.keys(), deps.object.values()) |name, *sub| {
                if (sub.* == .array or !instance.contains(name)) continue;
                if (!try k.inPlace(sub, k.collect) and k.failed()) return true;
            }
        };

        if (k.draft.atLeast(.draft6)) if (k.get("propertyNames")) |names| {
            for (keys) |key| {
                const name: Value = .{ .string = key };
                if (!try v.check(names, k.resource, &name, k.collect, null) and k.failed()) return true;
            }
        };

        const properties = if (k.get("properties")) |p| (if (p.* == .object) &p.object else null) else null;
        const patterns = if (k.get("patternProperties")) |p| (if (p.* == .object) &p.object else null) else null;
        const additional = k.get("additionalProperties");
        var unexpected: std.ArrayList([]const u8) = .empty;

        for (keys, values, 0..) |key, *value, i| {
            var matched = false;
            if (properties) |props| if (props.getPtr(key)) |sub| {
                matched = true;
                k.local.set(i);
                if (!try v.checkChild(sub, k.resource, value, .{ .key = key }, k.collect) and k.failed()) return true;
            };
            if (patterns) |pats| for (pats.keys(), pats.values()) |pattern, *sub| {
                const re = try v.registry.regex(pattern);
                if (!try re.search(v.arena, key)) continue;
                matched = true;
                k.local.set(i);
                if (!try v.checkChild(sub, k.resource, value, .{ .key = key }, k.collect) and k.failed()) return true;
            };
            if (matched) continue;
            const sub = additional orelse continue;
            k.local.set(i);
            if (sub.* == .bool and !sub.bool) {
                try unexpected.append(v.arena, key);
                if (k.failed()) return true;
            } else if (!try v.checkChild(sub, k.resource, value, .{ .key = key }, k.collect) and k.failed()) return true;
        }
        if (unexpected.items.len > 0 and k.collect) {
            try v.report("Additional properties are not allowed ({s} {s} unexpected)", .{ try quoteList(v.arena, unexpected.items), if (unexpected.items.len == 1) "was" else "were" });
        }
        return false;
    }

    fn dependentRequired(k: *Keywords, deps: *const std.json.ObjectMap) Error!bool {
        const instance = &k.instance.object;
        for (deps.keys(), deps.values()) |name, required| {
            if (required != .array or !instance.contains(name)) continue;
            for (required.array.items) |dependency| {
                if (dependency == .string and !instance.contains(dependency.string)) {
                    if (try k.report("{s} is a required property", .{try k.v.json(dependency)})) return true;
                }
            }
        }
        return false;
    }

    fn arrays(k: *Keywords) Error!bool {
        const items = switch (k.instance.*) {
            .array => |*a| a.items,
            else => return false,
        };
        const v = k.v;

        if (limit(k.get("minItems"))) |min| if (items.len < min) {
            if (try k.report("{s} has less than {d} item{s}", .{ try v.json(k.instance.*), min, plural(min) })) return true;
        };
        if (limit(k.get("maxItems"))) |max| if (items.len > max) {
            if (try k.report("{s} has more than {d} item{s}", .{ try v.json(k.instance.*), max, plural(max) })) return true;
        };
        if (k.get("uniqueItems")) |unique| if (unique.* == .bool and unique.bool) {
            outer: for (items, 0..) |a, i| {
                for (items[i + 1 ..]) |b| {
                    if (equal(a, b)) {
                        if (try k.report("{s} has non-unique elements", .{try v.json(k.instance.*)})) return true;
                        break :outer;
                    }
                }
            }
        };

        var prefix: ?[]const Value = null;
        var rest: ?*const Value = null;
        if (k.draft == .draft2020_12) {
            if (k.get("prefixItems")) |p| if (p.* == .array) {
                prefix = p.array.items;
            };
            rest = k.get("items");
        } else if (k.get("items")) |i| {
            if (i.* == .array) {
                prefix = i.array.items;
                rest = k.get("additionalItems");
            } else {
                rest = i;
            }
        }
        const prefix_len = if (prefix) |p| @min(p.len, items.len) else 0;
        if (prefix) |p| for (p[0..prefix_len], items[0..prefix_len], 0..) |*sub, *item, i| {
            k.local.set(i);
            if (!try v.checkChild(sub, k.resource, item, .{ .index = i }, k.collect) and k.failed()) return true;
        };
        if (rest) |sub| {
            if (sub.* == .bool and !sub.bool and items.len > prefix_len) {
                if (try k.report("Additional items are not allowed ({s} {s} unexpected)", .{ try v.json(items[prefix_len..]), if (items.len - prefix_len == 1) "was" else "were" })) return true;
            } else for (items[prefix_len..], prefix_len..) |*item, i| {
                if (!try v.checkChild(sub, k.resource, item, .{ .index = i }, k.collect) and k.failed()) return true;
            }
            k.local.setRangeValue(.{ .start = prefix_len, .end = items.len }, true);
        }

        if (k.draft.atLeast(.draft6)) if (k.get("contains")) |sub| {
            var count: usize = 0;
            for (items, 0..) |*item, i| {
                if (try v.check(sub, k.resource, item, false, null)) {
                    count += 1;
                    if (k.draft == .draft2020_12) k.local.set(i);
                }
            }
            const min = if (k.draft.atLeast(.draft2019_09)) limit(k.get("minContains")) orelse 1 else 1;
            const max = if (k.draft.atLeast(.draft2019_09)) limit(k.get("maxContains")) else null;
            if (count < min) {
                const shown = try v.json(k.instance.*);
                const stop = if (min == 1)
                    try k.report("None of {s} are valid under the given schema", .{shown})
                else
                    try k.report("{s} does not contain enough items valid under the given schema", .{shown});
                if (stop) return true;
            }
            if (max) |m| if (count > m) {
                if (try k.report("{s} contains too many items valid under the given schema", .{try v.json(k.instance.*)})) return true;
            };
        };
        return false;
    }

    fn unevaluated(k: *Keywords) Error!bool {
        if (!k.draft.atLeast(.draft2019_09)) return false;
        const v = k.v;
        switch (k.instance.*) {
            .object => |*object| if (k.get("unevaluatedProperties")) |sub| {
                var unexpected: std.ArrayList([]const u8) = .empty;
                for (object.keys(), object.values(), 0..) |key, *value, i| {
                    if (k.local.isSet(i)) continue;
                    if (sub.* == .bool and !sub.bool) {
                        try unexpected.append(v.arena, key);
                    } else if (!try v.checkChild(sub, k.resource, value, .{ .key = key }, k.collect) and k.failed()) return true;
                }
                if (unexpected.items.len > 0) {
                    if (try k.report("Unevaluated properties are not allowed ({s} {s} unexpected)", .{ try quoteList(v.arena, unexpected.items), if (unexpected.items.len == 1) "was" else "were" })) return true;
                }
                if (k.valid) k.local.setRangeValue(.{ .start = 0, .end = object.count() }, true);
            },
            .array => |*array| if (k.get("unevaluatedItems")) |sub| {
                var unexpected: std.ArrayList(Value) = .empty;
                for (array.items, 0..) |*item, i| {
                    if (k.local.isSet(i)) continue;
                    if (sub.* == .bool and !sub.bool) {
                        try unexpected.append(v.arena, item.*);
                    } else if (!try v.checkChild(sub, k.resource, item, .{ .index = i }, k.collect) and k.failed()) return true;
                }
                if (unexpected.items.len > 0) {
                    if (try k.report("Unevaluated items are not allowed ({s} {s} unexpected)", .{ try v.json(unexpected.items), if (unexpected.items.len == 1) "was" else "were" })) return true;
                }
                if (k.valid) k.local.setRangeValue(.{ .start = 0, .end = array.items.len }, true);
            },
            else => {},
        }
        return false;
    }
};

fn isTrue(schema: anytype, key: []const u8) bool {
    const object: *const std.json.ObjectMap = switch (@TypeOf(schema)) {
        *const Value => if (schema.* == .object) &schema.object else return false,
        else => schema,
    };
    const value = object.get(key) orelse return false;
    return value == .bool and value.bool;
}

fn plural(n: u64) []const u8 {
    return if (n == 1) "" else "s";
}

fn limit(value: ?*const Value) ?u64 {
    const v = value orelse return null;
    return switch (v.*) {
        .integer => |i| if (i >= 0) @intCast(i) else 0,
        .float => |f| if (f >= 0 and f == @floor(f)) @intFromFloat(@min(f, 1e18)) else null,
        else => null,
    };
}

fn number(value: Value) ?f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn isType(value: Value, name: []const u8, draft: Draft) bool {
    const map = std.StaticStringMap(enum { null, boolean, object, array, number, string, integer }).initComptime(.{
        .{ "null", .null },     .{ "boolean", .boolean }, .{ "object", .object },   .{ "array", .array },
        .{ "number", .number }, .{ "string", .string },   .{ "integer", .integer },
    });
    return switch (map.get(name) orelse return true) {
        .null => value == .null,
        .boolean => value == .bool,
        .object => value == .object,
        .array => value == .array,
        .string => value == .string,
        .number => number(value) != null,
        .integer => switch (value) {
            .integer => true,
            .float => |f| draft != .draft4 and f == @floor(f),
            .number_string => |s| blk: {
                const f = std.fmt.parseFloat(f64, s) catch break :blk false;
                break :blk std.mem.indexOfAny(u8, s, ".eE") == null or (draft != .draft4 and f == @floor(f));
            },
            else => false,
        },
    };
}

fn isMultiple(value: Value, divisor: Value, n: f64, d: f64) bool {
    if (value == .integer and divisor == .integer) {
        if (divisor.integer == 0) return true;
        return @rem(value.integer, divisor.integer) == 0;
    }
    if (d == 0) return true;
    const quotient = n / d;
    if (!std.math.isFinite(quotient)) return value == .integer or n == @floor(n) and 1 / d == @floor(1 / d);
    return @abs(quotient - @round(quotient)) < 1e-9;
}

fn equal(a: Value, b: Value) bool {
    if (number(a)) |x| if (number(b)) |y| {
        if (a == .integer and b == .integer) return a.integer == b.integer;
        return x == y;
    };
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| b == .array and x.items.len == b.array.items.len and for (x.items, b.array.items) |p, q| {
            if (!equal(p, q)) break false;
        } else true,
        .object => |x| b == .object and x.count() == b.object.count() and for (x.keys(), x.values()) |key, p| {
            const q = b.object.get(key) orelse break false;
            if (!equal(p, q)) break false;
        } else true,
        else => false,
    };
}

fn joinTypes(arena: Allocator, types: []const Value) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (types, 0..) |t, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        std.json.Stringify.value(t, .{}, &out.writer) catch return error.OutOfMemory;
    }
    return out.written();
}

fn quoteList(arena: Allocator, names: []const []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (names, 0..) |name, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.print("'{s}'", .{name}) catch return error.OutOfMemory;
    }
    return out.written();
}

const NoRetriever = struct {
    fn retrieve(_: *anyopaque, _: Allocator, location: []const u8, message: *[]const u8) error{ RetrieveFailed, OutOfMemory }![]const u8 {
        message.* = location;
        return error.RetrieveFailed;
    }
};

fn expectFailures(schema: []const u8, instance: []const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = Registry.init(arena, .{ .context = undefined, .retrieveFn = NoRetriever.retrieve });
    var message: []const u8 = "";
    try registry.add("urn:test", try parse(arena, schema, &message), .draft2020_12);
    const location = try registry.compile("urn:test", .draft2020_12);
    var failures: std.ArrayList(Failure) = .empty;
    const valid = try registry.validate(arena, location, &(try parse(arena, instance, &message)), &failures);
    try std.testing.expectEqual(expected.len == 0, valid);
    try std.testing.expectEqual(expected.len, failures.items.len);
    for (expected, failures.items) |e, f| {
        try std.testing.expectEqualStrings(e, try std.fmt.allocPrint(arena, "{s} (at {s})", .{ f.message, f.path }));
    }
}

test {
    _ = formats;
}

test "reports each failure with its instance path" {
    try expectFailures(
        \\{ "properties": { "a": { "type": "integer" }, "b": { "items": { "minimum": 2 } } }, "required": ["c"] }
    ,
        \\{ "a": "x", "b": [1, 3] }
    , &.{
        "\"c\" is a required property (at )",
        "\"x\" is not of type \"integer\" (at /a)",
        "1 is less than the minimum of 2 (at /b/0)",
    });
}

test "combinators report a single failure" {
    try expectFailures(
        \\{ "anyOf": [{ "type": "string" }, { "type": "null" }], "additionalProperties": false }
    , "1", &.{"1 is not valid under any of the schemas listed in the 'anyOf' keyword (at )"});
    try expectFailures(
        \\{ "additionalProperties": false, "properties": { "a/b": { "const": 1 } } }
    ,
        \\{ "a/b": 2, "x": 1, "y": 2 }
    , &.{
        "1 was expected (at /a~1b)",
        "Additional properties are not allowed ('x', 'y' were unexpected) (at )",
    });
}

test "valid instances report nothing" {
    try expectFailures(
        \\{ "$defs": { "n": { "type": "number" } }, "items": { "$ref": "#/$defs/n" } }
    , "[1, 2.5]", &.{});
}

test "unresolvable references fail at compile time" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = Registry.init(arena, .{ .context = undefined, .retrieveFn = NoRetriever.retrieve });
    var message: []const u8 = "";
    try registry.add("urn:test", try parse(arena, "{ \"$ref\": \"#/$defs/missing\" }", &message), .draft2020_12);
    try std.testing.expectError(error.SchemaError, registry.compile("urn:test", .draft2020_12));
    try std.testing.expectEqualStrings("unresolvable reference: urn:test#/$defs/missing", registry.message);
}

test "a failed compile does not affect the next schema" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = Registry.init(arena, .{ .context = undefined, .retrieveFn = NoRetriever.retrieve });
    var message: []const u8 = "";
    try registry.add("urn:broken", try parse(arena, "{ \"allOf\": [{ \"$ref\": \"#/a\" }, { \"$ref\": \"#/b\" }] }", &message), .draft2020_12);
    try registry.add("urn:fine", try parse(arena, "{ \"type\": \"object\" }", &message), .draft2020_12);
    try std.testing.expectError(error.SchemaError, registry.compile("urn:broken", .draft2020_12));
    _ = try registry.compile("urn:fine", .draft2020_12);
}
