const std = @import("std");
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the binary");

    const quickjs = b.dependency("quickjs", .{});
    const libregexp = b.addLibrary(.{
        .name = "regexp",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    libregexp.root_module.addCSourceFiles(.{
        .root = quickjs.path(""),
        .files = &.{ "libregexp.c", "libunicode.c" },
        .flags = &.{"-fno-sanitize=undefined"},
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "jsv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "build_options", .module = build_options.createModule() }},
        }),
    });
    exe.root_module.linkLibrary(libregexp);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run jsv").dependOn(&run.step);

    const test_step = b.step("test", "Run unit and CLI tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);

    const cli_options = b.addOptions();
    cli_options.addOptionPath("jsv", exe.getEmittedBin());
    cli_options.addOption([]const u8, "fixtures", b.pathFromRoot("tests/fixtures"));
    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "options", .module = cli_options.createModule() }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    const schema = b.createModule(.{ .root_source_file = b.path("src/schema.zig") });
    schema.linkLibrary(libregexp);
    const suite = b.addExecutable(.{
        .name = "suite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "schema", .module = schema }},
        }),
    });
    const run_suite = b.addRunArtifact(suite);
    if (b.args) |args| run_suite.addArgs(args);
    b.step("suite", "Run the JSON-Schema-Test-Suite (zig build suite -- <path>)").dependOn(&run_suite.step);
}
