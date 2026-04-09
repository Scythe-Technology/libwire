const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opt_verbose_asm = b.option(bool, "verbose-asm", "Enable verbose assembly output") orelse false;

    const options = b.addOptions();

    options.addOption(bool, "verbose_asm", opt_verbose_asm);

    const options_module = options.createModule();

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "ffi-asm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    lib.root_module.addImport("build_cfg", options_module);

    b.installArtifact(lib);

    const module = b.addModule("ffi-asm", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addImport("build_cfg", options_module);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{
            .mode = .simple,
            .path = b.path("runner.zig"),
        },
        .filters = b.args orelse &.{},
    });

    unit_tests.root_module.addImport("build_cfg", options_module);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    b.installArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const example_step = b.step("example", "Run example");

    const example = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("example/adder.zig"),
        }),
    });
    example.root_module.addImport("ffi-asm", module);
    const example_run = b.addRunArtifact(example);

    example_step.dependOn(&example_run.step);
}
