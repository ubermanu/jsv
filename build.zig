const std = @import("std");
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the binary");

    const pcre2 = b.dependency("pcre2", .{ .target = target, .optimize = optimize, .linkage = .static });
    const pcre2_h = b.addTranslateC(.{
        .root_source_file = pcre2.namedLazyPath("pcre2.h"),
        .target = target,
        .optimize = optimize,
    });
    pcre2_h.defineCMacro("PCRE2_CODE_UNIT_WIDTH", "8");
    pcre2_h.defineCMacro("PCRE2_STATIC", null);
    const regex: Regex = .{ .library = pcre2.artifact("pcre2-8"), .header = pcre2_h.createModule() };

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
    regex.addTo(exe.root_module);
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
    regex.addTo(schema);
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

const Regex = struct {
    library: *std.Build.Step.Compile,
    header: *std.Build.Module,

    fn addTo(regex: Regex, module: *std.Build.Module) void {
        module.addImport("pcre2", regex.header);
        module.linkLibrary(regex.library);
    }
};
