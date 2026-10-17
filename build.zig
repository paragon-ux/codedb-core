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

    // ── Version: package.json is the only source (`codedb --version`) ──
    const release_opts = b.addOptions();
    release_opts.addOption([]const u8, "semver", packageVersion(b));
    exe.root_module.addOptions("release_options", release_opts);

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

    // ── End-to-end: the CLI never touches upstream codedb's on-disk state ──
    const state_opts = b.addOptions();
    state_opts.addOptionPath("codedb_exe", exe.getEmittedBin());
    const state_tests = b.addTest(.{
        .name = "state-isolation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/state_isolation_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    state_tests.root_module.addOptions("build_options", state_opts);
    test_step.dependOn(&b.addRunArtifact(state_tests).step);

    // ── End-to-end: `codedb --version` prints package.json's version ──
    const version_opts = b.addOptions();
    version_opts.addOptionPath("codedb_exe", exe.getEmittedBin());
    version_opts.addOptionPath("package_json", b.path("package.json"));
    const version_tests = b.addTest(.{
        .name = "version",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/version_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    version_tests.root_module.addOptions("build_options", version_opts);
    test_step.dependOn(&b.addRunArtifact(version_tests).step);

    // ── End-to-end: call-graph JSON carries kind/qualified ──
    const json_opts = b.addOptions();
    json_opts.addOptionPath("codedb_exe", exe.getEmittedBin());
    const json_tests = b.addTest(.{
        .name = "neighbors-json",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/neighbors_json_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    json_tests.root_module.addOptions("build_options", json_opts);
    test_step.dependOn(&b.addRunArtifact(json_tests).step);
}

/// package.json's "version". Embedded, so editing package.json reconfigures
/// the build; a missing or non-semver version fails it.
fn packageVersion(b: *std.Build) []const u8 {
    const pkg = std.json.parseFromSliceLeaky(
        struct { version: []const u8 },
        b.allocator,
        @embedFile("package.json"),
        .{ .ignore_unknown_fields = true },
    ) catch |err| std.debug.panic("package.json: cannot read \"version\": {s}", .{@errorName(err)});
    _ = std.SemanticVersion.parse(pkg.version) catch |err|
        std.debug.panic("package.json: \"version\" \"{s}\" is not semver: {s}", .{ pkg.version, @errorName(err) });
    return pkg.version;
}
