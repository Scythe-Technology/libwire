const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const verbose_asm = b.option(bool, "verbose-asm", "Enable verbose assembly output") orelse false;
    const test_filter = b.option([]const u8, "test-filter", "filter a test");
    const llvm = b.option(bool, "llvm", "Enable LLVM backend");

    const options = b.addOptions();

    options.addOption(bool, "verbose_asm", verbose_asm);

    const options_module = options.createModule();

    const mod = b.addModule("root", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("build_config", options_module);

    const unit_tests = b.addTest(.{
        .root_module = mod,
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .use_llvm = llvm,
        .use_lld = llvm,
    });

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
    example.root_module.addImport("wire", mod);
    const example_run = b.addRunArtifact(example);

    example_step.dependOn(&example_run.step);

    const docs_step = b.step("docs", "Build documentation");

    const docs_obj = b.addObject(.{
        .name = "docs",
        .root_module = mod,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);
}
