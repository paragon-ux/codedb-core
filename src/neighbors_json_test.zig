//! End-to-end check of the call-graph JSON: every node `callers`, `callees`
//! and `neighbors` emit carries `kind` and `qualified`, and a qualified name
//! is accepted as the query.
const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const io = testing.io;

const svc_ts =
    \\export class Svc {
    \\  start(): number {
    \\    return target();
    \\  }
    \\}
    \\export function target(): number {
    \\  return 1;
    \\}
    \\target();
    \\
;

/// Runs `codedb <proj> <args...> --json` and returns stdout.
fn runJson(arena: std.mem.Allocator, exe: []const u8, proj: []const u8, args: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ exe, proj });
    try argv.appendSlice(arena, args);
    try argv.append(arena, "--json");
    var env = try testing.environ.createMap(arena);
    try env.put("CODEDB_ALLOW_TEMP", "1");
    try env.put("CODEDB_QUIET", "1");
    const result = try std.process.run(arena, io, .{ .argv = argv.items, .environ_map = &env });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("codedb {s} exited {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ args[0], code, result.stdout, result.stderr });
            return error.CommandFailed;
        },
        else => return error.CommandCrashed,
    }
    return result.stdout;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return;
    std.debug.print("missing {s}\nin {s}\n", .{ needle, haystack });
    return error.TestUnexpectedResult;
}

test "call-graph JSON: nodes carry kind and qualified, and qualified names resolve" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(io, "proj/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/src/svc.ts", .data = svc_ts });
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.codedb_exe, arena);
    const proj = try tmp.dir.realPathFileAlloc(io, "proj", arena);

    const callers = try runJson(arena, exe, proj, &.{ "callers", "target" });
    try expectContains(callers, "{\"path\":\"src/svc.ts\",\"name\":\"start\",\"line\":2,\"kind\":\"method\",\"qualified\":\"Svc.start\"}");
    try expectContains(callers, "{\"path\":\"src/svc.ts\",\"name\":\"<module>\",\"line\":1,\"kind\":\"module\",\"qualified\":\"<module>\"}");

    const callees = try runJson(arena, exe, proj, &.{ "callees", "Svc.start" });
    try expectContains(callees, "{\"path\":\"src/svc.ts\",\"name\":\"target\",\"line\":6,\"kind\":\"function\",\"qualified\":\"target\"}");

    const neighbors = try runJson(arena, exe, proj, &.{ "neighbors", "Svc.start" });
    try expectContains(neighbors, "\"symbol_exists\":true");
    try expectContains(neighbors, "\"callees\":{\"count\":1,\"results\":[{\"path\":\"src/svc.ts\",\"name\":\"target\",\"line\":6,\"kind\":\"function\",\"qualified\":\"target\"}]}");

    // A bare name still resolves as before.
    const bare = try runJson(arena, exe, proj, &.{ "neighbors", "start" });
    try expectContains(bare, "\"ambiguous\":false");
    try expectContains(bare, "\"name\":\"target\"");
}
