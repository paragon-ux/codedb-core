const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const codesign_identity = b.option(
        []const u8,
        "codesign-identity",
        "macOS codesign identity. Disabled by default and skipped for x86_64-macos.",
    );

    // ── Exposed module: importable as @import("codedb") ──
    const codedb_mod = b.addModule("codedb", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── CLI executable ──
    // In ReleaseFast/Small, strip debug info to shrink the binary (~10%).
    const strip_debug = optimize == .ReleaseFast or optimize == .ReleaseSmall;
    const exe = b.addExecutable(.{
        .name = "codedb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip_debug,
        }),
    });

    // ── nanoregex dependency ──
    const nanoregex_dep = b.dependency("nanoregex", .{});
    exe.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    codedb_mod.addImport("nanoregex", nanoregex_dep.module("nanoregex"));

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // macOS codesign, skipped for x86_64 (see upstream issue #504).
    if (codesign_identity) |identity| {
        const target_os = target.query.os_tag orelse target.result.os.tag;
        const target_arch = target.query.cpu_arch orelse target.result.cpu.arch;
        if (target_os == .macos and target_arch != .x86_64 and builtin.os.tag == .macos) {
            const codesign = b.addSystemCommand(&.{
                "codesign",
                "-f",
                "--options",
                "runtime",
                "--timestamp",
                "-s",
                identity,
                b.getInstallPath(.bin, "codedb"),
            });
            codesign.step.dependOn(&install_exe.step);
            b.getInstallStep().dependOn(&codesign.step);
        }
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run codedb");
    run_step.dependOn(&run_cmd.step);

    // ── Tests (verify the module root and the deterministic core compile) ──
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib_tests.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}
