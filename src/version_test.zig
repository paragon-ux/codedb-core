//! End-to-end check that the built CLI reports package.json's version.
//!
//! 2.0.1 shipped printing `codedb 0.2.5828`, a constant inherited from
//! upstream justrach/codedb. The version now comes from package.json via
//! build.zig; this reads package.json itself and runs the binary, so any
//! hardcoded or stale version fails `zig build test`.
const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const io = testing.io;

/// Every way to ask for the version: the argv[1] fast path, and the
/// `<root> <command>` path taken after root parsing.
const invocations = [_][]const []const u8{
    &.{"--version"},
    &.{"-v"},
    &.{"version"},
    &.{ ".", "--version" },
};

fn packageVersion(arena: std.mem.Allocator) ![]const u8 {
    const body = try std.Io.Dir.cwd().readFileAlloc(io, build_options.package_json, arena, .limited(1 << 20));
    const pkg = try std.json.parseFromSliceLeaky(
        struct { version: []const u8 },
        arena,
        body,
        .{ .ignore_unknown_fields = true },
    );
    return pkg.version;
}

/// Runs `codedb <args...>`; returns its stdout.
fn run(arena: std.mem.Allocator, exe: []const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, exe);
    try argv.appendSlice(arena, args);
    const result = try std.process.run(arena, io, .{ .argv = argv.items });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("codedb {s} exited {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ args[args.len - 1], code, result.stdout, result.stderr });
            return error.CommandFailed;
        },
        else => return error.CommandCrashed,
    }
    return result.stdout;
}

test "version: codedb --version prints package.json's version" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.codedb_exe, arena);
    const expected = try std.fmt.allocPrint(arena, "codedb {s}", .{try packageVersion(arena)});
    for (invocations) |args| {
        const stdout = try run(arena, exe, args);
        // On Windows the C runtime writes stdout in text mode (`\r\n`).
        const line = std.mem.trimEnd(u8, stdout, "\r\n");
        testing.expectEqualStrings(expected, line) catch |err| {
            std.debug.print("from: codedb {s}\n", .{std.mem.join(arena, " ", args) catch "?"});
            return err;
        };
    }
}
