//! Startup bootstrap for the one-shot CLI: config resolution, data-dir
//! resolution, and the fresh-scan index build. No snapshot, git-head tracking,
//! disk persistence, warmup threads, or daemon modes — every invocation scans
//! the project once and answers the query, then exits.
const std = @import("std");
const cio = @import("cio.zig");
const Config = @import("config.zig").Config;
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const WordIndex = @import("index.zig").WordIndex;
const watcher = @import("watcher.zig");
const index_mod = @import("index.zig");
const sty = @import("style.zig");
const Out = @import("out.zig").Out;

/// Resolve config from the (already-extracted) --config-file path, falling
/// back to $CWD/.codedbrc and then <binary_dir>/.codedbrc. Returns the
/// default Config if nothing is found.
pub fn loadUserConfig(io: std.Io, alloc: std.mem.Allocator, explicit: ?[]const u8) !Config {
    const self_exe: ?[:0]u8 = std.process.executablePathAlloc(io, alloc) catch null;
    defer if (self_exe) |p| alloc.free(p);
    const bin_dir: ?[]const u8 = if (self_exe) |p| blk: {
        const last_slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse break :blk null;
        break :blk p[0..last_slash];
    } else null;

    return try Config.loadDefault(io, alloc, explicit, bin_dir);
}

pub fn getDataDir(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, abs_root);
    const home_env = cio.homeDir() orelse {
        return std.fmt.allocPrint(allocator, "{s}/.codedb", .{abs_root});
    };
    const home = try allocator.dupe(u8, home_env);
    defer allocator.free(home);
    const dir = try std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash });
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.log.warn("could not create data dir {s}: {}", .{ dir, err });
    };
    return dir;
}

/// Fresh-scan index bootstrap for a single query. `search` builds the trigram
/// index in one pass (plus outlines + word index); every other command scans
/// outlines + word index only. No persistence — the process exits after one
/// answer.
pub fn coldLoadOrScan(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    explorer: *Explorer,
    out: *Out,
    s: sty.Style,
    cmd: []const u8,
    root: []const u8,
    freq_table_heap: *?*[256][256]u16,
) !void {
    _ = freq_table_heap;

    const is_search = std.mem.eql(u8, cmd, "search");
    const needs_word = is_search or std.mem.eql(u8, cmd, "word");

    // Use c_allocator for the word index during scan — freed pages return to
    // the OS immediately instead of c_allocator retention.
    explorer.mu.lock();
    explorer.word_index.deinit();
    explorer.word_index = WordIndex.init(std.heap.c_allocator);
    explorer.mu.unlock();
    // Skip file_words tracking during bulk scan (only needed for removeFile).
    explorer.word_index.skip_file_words = true;
    if (!needs_word) explorer.word_index.enabled = false;

    const t_scan = cio.nanoTimestamp();
    if (is_search) {
        const tmp_tri = try watcher.initialScanWithTrigrams(io, store, explorer, root, allocator, std.heap.c_allocator, false);
        if (tmp_tri) |tri| {
            explorer.adoptTrigramIndex(.{ .heap = tri.* });
            std.heap.c_allocator.destroy(tri);
        }
    } else {
        try watcher.initialScan(io, store, explorer, root, allocator, true);
    }
    const scan_elapsed = cio.nanoTimestamp() - t_scan;
    if (cio.posixGetenv("CODEDB_QUIET") == null) {
        var dur_buf: [64]u8 = undefined;
        out.p("{s}\xe2\x9c\x93{s} {s}indexed{s}  {s}{s}{s}\n", .{
            s.green, s.reset,
            s.dim,   s.reset,
            sty.durationColor(s, scan_elapsed), sty.formatDuration(&dur_buf, scan_elapsed),
            s.reset,
        });
    }
}
