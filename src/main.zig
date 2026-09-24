const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const sty = @import("style.zig");
const index_mod = @import("index.zig");
const root_policy = @import("root_policy.zig");
const release_info = @import("release_info.zig");
const Config = @import("config.zig").Config;

const out_mod = @import("out.zig");
const Out = out_mod.Out;
const printUsage = out_mod.printUsage;
const cli_args = @import("cli_args.zig");
pub const parsePositional = cli_args.parsePositional;
const isHelpRequest = cli_args.isHelpRequest;
const resolveRoot = cli_args.resolveRoot;
const cliIsQueryCmd = cli_args.cliIsQueryCmd;

const query_mod = @import("query.zig");
const runQuery = query_mod.runQuery;
const bootstrap = @import("bootstrap.zig");
const loadUserConfig = bootstrap.loadUserConfig;
const getDataDir = bootstrap.getDataDir;

/// In Debug builds Zig may merge all command-branch stack frames into one
/// that overflows the default OS stack, so we trampoline through a thread
/// with an explicit stack size (see upstream #504). The entry point stays
/// synchronous + infallible; fallible work runs in mainImpl.
pub fn main(init: std.process.Init.Minimal) void {
    const argv = cio.bootstrapArgs(init.args);
    cio.setProcessArgs(argv);
    if (handleFastPath(argv)) return;
    mainTrampoline() catch |err| {
        var buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "codedb: fatal startup error: {s}\n", .{@errorName(err)})) |msg| {
            cio.File.stderr().writeAll(msg) catch {};
        } else |_| {}
        std.process.exit(1);
    };
}

fn mainTrampoline() !void {
    const stack_size: usize = if (builtin.mode == .Debug) 64 * 1024 * 1024 else 8 * 1024 * 1024;
    const thread = try std.Thread.spawn(.{ .stack_size = stack_size }, mainInner, .{});
    thread.join();
}

fn handleFastPath(argv: []const [*:0]const u8) bool {
    const stdout_fd: c_int = 1;
    const stderr_fd: c_int = 2;

    if (argv.len < 2) {
        const msg =
            "codedb  deterministic structural code intelligence\n\n" ++
            "  usage: codedb [root] <command> [args...]\n\n" ++
            "  run `codedb --help` for the full command list.\n";
        (cio.File{ .handle = stderr_fd }).writeAll(msg) catch {};
        std.process.exit(1);
    }

    const a1 = std.mem.span(argv[1]);
    if (std.mem.eql(u8, a1, "--version") or std.mem.eql(u8, a1, "-v") or std.mem.eql(u8, a1, "version")) {
        var buf: [128]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "codedb {s}\n", .{release_info.semver}) catch std.process.exit(0);
        (cio.File{ .handle = stdout_fd }).writeAll(out) catch {};
        std.process.exit(0);
    }

    return false;
}

fn mainInner() void {
    mainImpl() catch |err| {
        std.debug.print("fatal: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn mainImpl() !void {
    const allocator = std.heap.c_allocator;
    cio.ignoreSigpipe();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stdout = cio.File.stdout();
    const use_color = stdout.isTty();
    const s = sty.style(use_color);
    var out = Out{ .file = stdout, .alloc = allocator };
    defer out.flush();

    const raw_args = try cio.argsAlloc(allocator);
    defer cio.argsFree(allocator, raw_args);

    // Extract --config-file=<path> / --config-file <path> before positional
    // parsing; also honor --allow-temp for CI harnesses.
    var explicit_config: ?[]const u8 = null;
    const args = blk: {
        var filtered: std.ArrayList([]const u8) = .empty;
        errdefer filtered.deinit(allocator);
        try filtered.append(allocator, raw_args[0]);
        var i: usize = 1;
        while (i < raw_args.len) : (i += 1) {
            const a = raw_args[i];
            if (std.mem.startsWith(u8, a, "--config-file=")) {
                explicit_config = a["--config-file=".len..];
                continue;
            } else if (std.mem.eql(u8, a, "--config-file") and i + 1 < raw_args.len) {
                explicit_config = raw_args[i + 1];
                i += 1;
                continue;
            } else if (std.mem.eql(u8, a, "--allow-temp")) {
                cio.posixSetenv("CODEDB_ALLOW_TEMP", "1");
                continue;
            }
            try filtered.append(allocator, a);
        }
        break :blk try filtered.toOwnedSlice(allocator);
    };
    defer allocator.free(args);

    const parsed = parsePositional(args);
    if (parsed.usage_exit) {
        printUsage(&out, s);
        out.exitWithFlush(1);
    }
    const root = parsed.root;
    const cmd = parsed.cmd;
    const cmd_args_start = parsed.cmd_args_start;

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "version")) {
        out.p("codedb {s}\n", .{release_info.semver});
        return;
    }
    if (isHelpRequest(cmd)) {
        printUsage(&out, s);
        return;
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_root = resolveRoot(io, root, &root_buf) catch {
        out.p("{s}\xe2\x9c\x97{s} cannot resolve root: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, root, s.reset });
        out.exitWithFlush(1);
    };
    if (!root_policy.isIndexableRoot(abs_root)) {
        out.p("{s}\xe2\x9c\x97{s} refusing to index temporary root: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, abs_root, s.reset });
        out.exitWithFlush(1);
    }

    const data_dir = try getDataDir(io, allocator, abs_root);
    defer allocator.free(data_dir);

    const cfg = loadUserConfig(io, allocator, explicit_config) catch |err| blk: {
        std.log.warn("config load failed ({s}) — using defaults", .{@errorName(err)});
        break :blk Config.default;
    };

    var store = Store.init(allocator);
    store.max_versions = cfg.max_versions;
    defer store.deinit();

    const data_log_path = try std.fmt.allocPrint(allocator, "{s}/data.log", .{data_dir});
    defer allocator.free(data_log_path);
    store.openDataLog(io, data_log_path) catch |err| {
        std.log.warn("could not open data log at {s}: {}", .{ data_log_path, err });
    };

    var explorer = Explorer.init(allocator, cfg.max_cached);
    explorer.setRoot(io, root);
    defer explorer.deinit();

    var freq_table_heap: ?*[256][256]u16 = null;
    defer if (freq_table_heap) |ft| {
        index_mod.resetFrequencyTable();
        allocator.destroy(ft);
    };

    try bootstrap.coldLoadOrScan(io, allocator, &store, &explorer, &out, s, cmd, root, &freq_table_heap);

    if (cliIsQueryCmd(cmd)) {
        const code = runQuery(io, allocator, &explorer, &store, abs_root, cmd, args, cmd_args_start, &out, s);
        out.flush();
        std.process.exit(code);
    } else {
        out.p("{s}\xe2\x9c\x97{s} unknown command: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, cmd, s.reset });
        out.flush();
        std.process.exit(1);
    }
}
