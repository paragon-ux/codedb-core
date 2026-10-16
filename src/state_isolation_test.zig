//! End-to-end check that the codedb-core CLI never touches upstream
//! justrach/codedb's on-disk state (`~/.codedb/` and `.codedbrc`).
//!
//! Runs the built binary against a throwaway project with HOME/USERPROFILE and
//! the working directory pointed at temp dirs seeded with upstream files, then
//! asserts the whole temp tree is unchanged: seeded files stay byte-identical
//! and nothing new appears (no `.codedb-core` data dir either). A malformed
//! `.codedbrc` doubles as a read sentinel: if the fork parsed it, the CLI would
//! log "config load failed".
const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const io = testing.io;

const upstream_log_body = "upstream codedb data.log - must survive untouched\n";
/// Fails Config.parse if anything reads it.
const malformed_rc = "max_versions = not_a_number\n";
const config_failed_marker = "config load failed";

const project_src =
    \\function helper() { return 1; }
    \\function main() { return helper(); }
    \\
;

/// Representative one-shot commands (Waymark calls these by absolute path).
const commands = [_][]const []const u8{
    &.{"tree"},
    &.{ "outline", "app.js" },
    &.{ "search", "helper" },
    &.{ "symbol", "helper" },
    &.{ "callers", "helper" },
    &.{ "callees", "main" },
    &.{ "neighbors", "helper" },
    &.{"status"},
};

const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    /// Absolute, so it still resolves once the child's cwd changes.
    exe: []const u8,
    home: []const u8,
    cwd: []const u8,
    proj: []const u8,

    fn init() !Fixture {
        var f: Fixture = .{
            .tmp = testing.tmpDir(.{ .iterate = true }),
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .exe = undefined,
            .home = undefined,
            .cwd = undefined,
            .proj = undefined,
        };
        errdefer f.deinit();
        const arena = f.arena_state.allocator();
        for ([_][]const u8{ "home", "cwd", "proj" }) |sub| try f.tmp.dir.createDirPath(io, sub);
        f.exe = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.codedb_exe, arena);
        f.home = try f.tmp.dir.realPathFileAlloc(io, "home", arena);
        f.cwd = try f.tmp.dir.realPathFileAlloc(io, "cwd", arena);
        f.proj = try f.tmp.dir.realPathFileAlloc(io, "proj", arena);
        try f.tmp.dir.writeFile(io, .{ .sub_path = "proj/app.js", .data = project_src });
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
        f.tmp.cleanup();
    }

    fn write(f: *Fixture, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |parent| try f.tmp.dir.createDirPath(io, parent);
        try f.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    }

    /// Seed every location upstream codedb reads or writes for `proj`.
    fn seedUpstreamState(f: *Fixture) !void {
        const arena = f.arena_state.allocator();
        // Upstream's per-project data dir: $HOME/.codedb/projects/<wyhash(abs_root)>.
        const hash = std.hash.Wyhash.hash(0, f.proj);
        const home_log = try std.fmt.allocPrint(arena, "home/.codedb/projects/{x}/data.log", .{hash});
        try f.write(home_log, upstream_log_body);
        // Upstream's no-HOME fallback: <root>/.codedb/data.log.
        try f.write("proj/.codedb/data.log", upstream_log_body);
        // Upstream's config names: $CWD/.codedbrc and $HOME/.codedbrc.
        try f.write("cwd/.codedbrc", malformed_rc);
        try f.write("home/.codedbrc", malformed_rc);
    }

    fn env(f: *Fixture, with_home: bool) !std.process.Environ.Map {
        var map = try testing.environ.createMap(f.arena_state.allocator());
        errdefer map.deinit();
        _ = map.swapRemove("HOME");
        _ = map.swapRemove("USERPROFILE");
        if (with_home) {
            try map.put("HOME", f.home);
            try map.put("USERPROFILE", f.home);
        }
        // The fixture lives under .zig-cache/tmp; never trip the temp-root guard.
        try map.put("CODEDB_ALLOW_TEMP", "1");
        _ = map.swapRemove("CODEDB_QUIET");
        return map;
    }

    /// Runs `codedb <abs proj> <args...>` from `cwd`; returns its stderr.
    fn run(f: *Fixture, env_map: *const std.process.Environ.Map, args: []const []const u8) ![]const u8 {
        const arena = f.arena_state.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ f.exe, f.proj });
        try argv.appendSlice(arena, args);
        const result = try std.process.run(arena, io, .{
            .argv = argv.items,
            .cwd = .{ .path = f.cwd },
            .environ_map = env_map,
        });
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("codedb {s} exited {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ args[0], code, result.stdout, result.stderr });
                return error.CommandFailed;
            },
            else => return error.CommandCrashed,
        }
        return result.stderr;
    }
};

const Entry = struct {
    path: []const u8,
    body: ?[]const u8,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

fn snapshot(arena: std.mem.Allocator, dir: std.Io.Dir) ![]const Entry {
    var list: std.ArrayList(Entry) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        const body: ?[]const u8 = if (e.kind == .file)
            try dir.readFileAlloc(io, e.path, arena, .limited(1 << 20))
        else
            null;
        try list.append(arena, .{ .path = try arena.dupe(u8, e.path), .body = body });
    }
    std.mem.sort(Entry, list.items, {}, Entry.lessThan);
    return list.items;
}

fn expectSameTree(before: []const Entry, after: []const Entry) !void {
    var ok = before.len == after.len;
    if (ok) for (before, after) |b, a| {
        if (!std.mem.eql(u8, b.path, a.path)) ok = false;
        if ((b.body == null) != (a.body == null)) ok = false;
        if (b.body != null and a.body != null and !std.mem.eql(u8, b.body.?, a.body.?)) ok = false;
    };
    if (ok) return;
    std.debug.print("temp tree changed\nbefore:\n", .{});
    for (before) |e| std.debug.print("  {s} {d}\n", .{ e.path, if (e.body) |b| b.len else 0 });
    std.debug.print("after:\n", .{});
    for (after) |e| std.debug.print("  {s} {d}\n", .{ e.path, if (e.body) |b| b.len else 0 });
    return error.TreeChanged;
}

test "state isolation: upstream ~/.codedb data.log and .codedbrc are untouched and unread" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.seedUpstreamState();
    const arena = f.arena_state.allocator();
    const before = try snapshot(arena, f.tmp.dir);

    var env_home = try f.env(true);
    for (commands) |args| {
        const stderr = try f.run(&env_home, args);
        if (std.mem.indexOf(u8, stderr, config_failed_marker) != null) {
            std.debug.print("codedb {s} read upstream .codedbrc:\n{s}\n", .{ args[0], stderr });
            return error.UpstreamConfigRead;
        }
    }

    // Without a home dir upstream falls back to <root>/.codedb.
    var env_no_home = try f.env(false);
    for ([_][]const []const u8{ &.{"tree"}, &.{ "callers", "helper" } }) |args| {
        _ = try f.run(&env_no_home, args);
    }

    try expectSameTree(before, try snapshot(arena, f.tmp.dir));
}

test "state isolation: the fork's own .codedb-corerc is read from the working directory" {
    // Control for the sentinel above: the same malformed body under the fork's
    // config name must be parsed (and rejected), proving the marker fires.
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("cwd/.codedb-corerc", malformed_rc);
    var env_home = try f.env(true);
    const stderr = try f.run(&env_home, &.{"tree"});
    try testing.expect(std.mem.indexOf(u8, stderr, config_failed_marker) != null);
}
