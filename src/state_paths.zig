//! On-disk names owned by codedb-core.
//!
//! The fork never reads or writes upstream justrach/codedb's state
//! (`~/.codedb/`, `<root>/.codedb/`, `.codedbrc`), so running both tools on the
//! same project can't share or clobber anything.
//!
//! The one-shot CLI keeps no state on disk: every run scans the project in
//! memory, answers, and exits, so it never creates a data dir. The only file it
//! reads besides the project is the optional config. `projectDataDir` reserves
//! the location any future persisted state must use.
const std = @import("std");

/// Config file name, looked up in $CWD and then next to the binary.
pub const config_file_name = ".codedb-corerc";

/// Data dir name, under the home dir (or the project root without one).
pub const data_dir_name = ".codedb-core";

/// `<home>/.codedb-core/projects/<wyhash(abs_root)>`, or
/// `<abs_root>/.codedb-core` when there is no home dir. Path only: never
/// creates the directory.
pub fn projectDataDir(allocator: std.mem.Allocator, home: ?[]const u8, abs_root: []const u8) ![]u8 {
    if (home) |h| if (h.len > 0) {
        const hash = std.hash.Wyhash.hash(0, abs_root);
        return std.fmt.allocPrint(allocator, "{s}/" ++ data_dir_name ++ "/projects/{x}", .{ h, hash });
    };
    return std.fmt.allocPrint(allocator, "{s}/" ++ data_dir_name, .{abs_root});
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectNotUpstream(path: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, path, "/.codedb/") == null);
    try testing.expect(!std.mem.endsWith(u8, path, "/.codedb"));
    try testing.expect(std.mem.indexOf(u8, path, ".codedbrc") == null);
}

test "state_paths: home data dir is per-project under .codedb-core" {
    const root = "/work/project";
    const dir = try projectDataDir(testing.allocator, "/home/dev", root);
    defer testing.allocator.free(dir);
    const expected = try std.fmt.allocPrint(testing.allocator, "/home/dev/.codedb-core/projects/{x}", .{std.hash.Wyhash.hash(0, root)});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, dir);
    try expectNotUpstream(dir);
}

test "state_paths: no home dir falls back to <root>/.codedb-core" {
    for ([_]?[]const u8{ null, "" }) |home| {
        const dir = try projectDataDir(testing.allocator, home, "/work/project");
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings("/work/project/.codedb-core", dir);
        try expectNotUpstream(dir);
    }
}

test "state_paths: names differ from upstream codedb" {
    try testing.expect(!std.mem.eql(u8, config_file_name, ".codedbrc"));
    try testing.expect(!std.mem.eql(u8, data_dir_name, ".codedb"));
}
