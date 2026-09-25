//! Read-only query command dispatch for the one-shot CLI. Renders every
//! deterministic structural tool directly over the Explorer engine — no MCP
//! bridge, no telemetry, no daemon. Each command supports `--json` for
//! machine-readable output.
const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
const sty = @import("style.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const explore_mod = @import("explore.zig");
const watcher = @import("watcher.zig");
const Out = @import("out.zig").Out;
const cli_args = @import("cli_args.zig");
const parseSearchArgs = cli_args.parseSearchArgs;
const parseLineRange = cli_args.parseLineRange;

fn hasJsonFlag(args: []const []const u8, start: usize) bool {
    for (args[start..]) |a| {
        if (std.mem.eql(u8, a, "--json")) return true;
    }
    return false;
}

fn appendJsonStr(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    const hexdigits = "0123456789abcdef";
    out.append(a, '"') catch return;
    for (s) |c| {
        switch (c) {
            '"' => out.appendSlice(a, "\\\"") catch return,
            '\\' => out.appendSlice(a, "\\\\") catch return,
            '\n' => out.appendSlice(a, "\\n") catch return,
            '\r' => out.appendSlice(a, "\\r") catch return,
            '\t' => out.appendSlice(a, "\\t") catch return,
            0...8, 11, 12, 14...0x1f => {
                out.appendSlice(a, "\\u00") catch return;
                out.append(a, hexdigits[(c >> 4) & 0xf]) catch return;
                out.append(a, hexdigits[c & 0xf]) catch return;
            },
            else => out.append(a, c) catch return,
        }
    }
    out.append(a, '"') catch return;
}

fn jsonInt(a: std.mem.Allocator, buf: *std.ArrayList(u8), v: anytype) void {
    var b: [24]u8 = undefined;
    buf.appendSlice(a, std.fmt.bufPrint(&b, "{d}", .{v}) catch "0") catch {};
}

/// Collect positional (non-flag) args, skipping `--json`.
fn positionals(a: std.mem.Allocator, args: []const []const u8, start: usize, out: *std.ArrayList([]const u8)) void {
    var i = start;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) continue;
        if (arg.len > 0 and arg[0] == '-') continue;
        out.append(a, arg) catch return;
    }
}

pub fn runQuery(
    io: std.Io,
    allocator: std.mem.Allocator,
    explorer: *Explorer,
    store: *Store,
    root: []const u8,
    cmd: []const u8,
    args: []const []const u8,
    cmd_args_start: usize,
    out: *Out,
    s: sty.Style,
) u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json = hasJsonFlag(args, cmd_args_start);

    if (std.mem.eql(u8, cmd, "tree")) return runTree(explorer, a, out, s, json);
    if (std.mem.eql(u8, cmd, "outline")) return runOutline(explorer, a, out, s, json, args, cmd_args_start);
    if (std.mem.eql(u8, cmd, "find")) return runFind(explorer, a, out, s, args, cmd_args_start);
    if (std.mem.eql(u8, cmd, "symbol")) return runSymbol(explorer, a, out, s, json, args, cmd_args_start);
    if (std.mem.eql(u8, cmd, "neighbors")) return runCombinedNeighbors(explorer, a, out, s, json, args, cmd_args_start, null);
    if (std.mem.eql(u8, cmd, "callers")) return runNeighbors(explorer, a, out, s, json, true, args, cmd_args_start, null);
    if (std.mem.eql(u8, cmd, "callees")) return runNeighbors(explorer, a, out, s, json, false, args, cmd_args_start, null);
    if (std.mem.eql(u8, cmd, "serve")) return runServe(io, allocator, explorer, store, root, out, s);
    if (std.mem.eql(u8, cmd, "callpath")) return runCallpath(explorer, a, out, s, json, args, cmd_args_start);
    if (std.mem.eql(u8, cmd, "deps")) return runDeps(explorer, a, out, s, json, args, cmd_args_start);
    if (std.mem.eql(u8, cmd, "search")) return runSearch(explorer, a, out, s, args, cmd_args_start);
    if (std.mem.eql(u8, cmd, "word")) return runWord(explorer, a, out, s, args, cmd_args_start);
    if (std.mem.eql(u8, cmd, "read")) return runRead(io, explorer, a, out, s, root, args, cmd_args_start);
    if (std.mem.eql(u8, cmd, "hot")) return runHot(explorer, store, a, out, s);
    if (std.mem.eql(u8, cmd, "status")) return runStatus(explorer, store, out, s, root);
    if (std.mem.eql(u8, cmd, "glob")) return runGlob(explorer, a, out, s, args, cmd_args_start);
    if (std.mem.eql(u8, cmd, "ls")) return runLs(explorer, a, out, s, args, cmd_args_start);
    if (std.mem.eql(u8, cmd, "file")) return runFile(explorer, a, out, s, args, cmd_args_start);
    return 1;
}

// ── tree ──────────────────────────────────────────────────────────────────

fn runTree(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, json: bool) u8 {
    if (json) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        buf.appendSlice(a, "{\"ok\":true,\"tool\":\"tree\",\"files\":[") catch {};
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();
        var first = true;
        var it = explorer.outlines.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const fo = entry.value_ptr;
            if (!first) buf.append(a, ',') catch {};
            first = false;
            buf.append(a, '{') catch {};
            buf.appendSlice(a, "\"path\":") catch {};
            appendJsonStr(a, &buf, path);
            buf.appendSlice(a, ",\"language\":") catch {};
            appendJsonStr(a, &buf, @tagName(fo.language));
            buf.appendSlice(a, ",\"line_count\":") catch {};
            jsonInt(a, &buf, fo.line_count);
            buf.appendSlice(a, ",\"sym_count\":") catch {};
            jsonInt(a, &buf, fo.symbols.items.len);
            buf.append(a, '}') catch {};
        }
        buf.appendSlice(a, "]}\n") catch {};
        out.p("{s}", .{buf.items});
        return 0;
    }
    const tree = explorer.getTree(a, s.reset.len != 0) catch return 1;
    out.p("{s}", .{tree});
    return 0;
}

// ── outline ───────────────────────────────────────────────────────────────

fn runOutline(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, json: bool, args: []const []const u8, start: usize) u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    positionals(a, args, start, &pos);
    if (pos.items.len < 1) {
        out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] outline {s}<path>{s}\n", .{ s.red, s.reset, s.cyan, s.reset });
        return 1;
    }
    const path = pos.items[0];
    var outline = explorer.getOutline(path, a) catch {
        out.p("{s}\xe2\x9c\x97{s} not indexed: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, path, s.reset });
        return 1;
    } orelse {
        out.p("{s}\xe2\x9c\x97{s} not indexed: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, path, s.reset });
        return 1;
    };
    defer outline.deinit();

    if (json) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        buf.appendSlice(a, "{\"ok\":true,\"tool\":\"outline\",\"path\":") catch {};
        appendJsonStr(a, &buf, path);
        buf.appendSlice(a, ",\"language\":") catch {};
        appendJsonStr(a, &buf, @tagName(outline.language));
        buf.appendSlice(a, ",\"line_count\":") catch {};
        jsonInt(a, &buf, outline.line_count);
        buf.appendSlice(a, ",\"symbols\":[") catch {};
        for (outline.symbols.items, 0..) |sym, i| {
            if (i > 0) buf.append(a, ',') catch {};
            buf.append(a, '{') catch {};
            buf.appendSlice(a, "\"name\":") catch {};
            appendJsonStr(a, &buf, sym.name);
            buf.appendSlice(a, ",\"kind\":") catch {};
            appendJsonStr(a, &buf, @tagName(sym.kind));
            buf.appendSlice(a, ",\"line_start\":") catch {};
            jsonInt(a, &buf, sym.line_start);
            buf.appendSlice(a, ",\"line_end\":") catch {};
            jsonInt(a, &buf, sym.line_end);
            if (sym.detail) |d| {
                buf.appendSlice(a, ",\"detail\":") catch {};
                appendJsonStr(a, &buf, d);
            }
            buf.append(a, '}') catch {};
        }
        buf.appendSlice(a, "]}\n") catch {};
        out.p("{s}", .{buf.items});
        return 0;
    }

    const lang = @tagName(outline.language);
    out.p("{s}\xe2\x9c\x93{s} {s}{s}{s}  {s}{s}{s}  {s}{d} lines{s}\n", .{
        s.green, s.reset, s.bold, path, s.reset, s.langColor(lang), lang, s.reset, s.dim, outline.line_count, s.reset,
    });
    for (outline.symbols.items) |sym| {
        const kind = @tagName(sym.kind);
        out.p("  {s}L{d:<5}{s}  {s}{s:<14}{s}  {s}{s}{s}", .{
            s.dim, sym.line_start, s.reset, s.kindColor(kind), kind, s.reset, s.bold, sym.name, s.reset,
        });
        if (sym.detail) |d| out.p("  {s}{s}{s}", .{ s.dim, d, s.reset });
        out.p("\n", .{});
    }
    return 0;
}

// ── find ──────────────────────────────────────────────────────────────────

fn runFind(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, args: []const []const u8, start: usize) u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    positionals(a, args, start, &pos);
    if (pos.items.len < 1) {
        out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] find {s}<symbol>{s}\n", .{ s.red, s.reset, s.cyan, s.reset });
        return 1;
    }
    const name = pos.items[0];
    if (explorer.findSymbol(name, a) catch return 1) |r| {
        const kind = @tagName(r.symbol.kind);
        out.p("{s}\xe2\x9c\x93{s} {s}{s}{s} {s}{s}{s}  {s}{s}{s}:{s}{d}{s}\n", .{
            s.green, s.reset, s.kindColor(kind), kind, s.reset, s.bold, name, s.reset, s.dim, r.path, s.reset, s.cyan, r.symbol.line_start, s.reset,
        });
        if (r.symbol.detail) |d| out.p("  {s}{s}{s}\n", .{ s.dim, d, s.reset });
        return 0;
    }
    out.p("{s}\xe2\x9c\x97{s} not found: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, name, s.reset });
    return 1;
}

// ── symbol ────────────────────────────────────────────────────────────────

fn runSymbol(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, json: bool, args: []const []const u8, start: usize) u8 {
    var name: ?[]const u8 = null;
    var prefix: ?[]const u8 = null;
    var pattern: ?[]const u8 = null;
    var kind_filter: ?explore_mod.SymbolKind = null;
    var fuzzy = false;
    var max_results: usize = 50;
    var body = false;
    var i = start;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) continue;
        if (std.mem.eql(u8, arg, "--fuzzy")) { fuzzy = true; continue; }
        if (std.mem.eql(u8, arg, "--body")) { body = true; continue; }
        if (std.mem.eql(u8, arg, "--prefix")) { if (i + 1 >= args.len) return 1; i += 1; prefix = args[i]; continue; }
        if (std.mem.eql(u8, arg, "--pattern")) { if (i + 1 >= args.len) return 1; i += 1; pattern = args[i]; continue; }
        if (std.mem.eql(u8, arg, "--kind")) { if (i + 1 >= args.len) return 1; i += 1; kind_filter = explore_mod.Explorer.parseSymbolKind(args[i]); continue; }
        if (std.mem.eql(u8, arg, "--max-results")) { if (i + 1 >= args.len) return 1; i += 1; max_results = std.fmt.parseInt(usize, args[i], 10) catch 50; continue; }
        if (arg.len > 0 and arg[0] == '-') continue;
        if (name == null) { name = arg; continue; }
    }
    const n = name orelse {
        out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] symbol {s}<name>{s} [--prefix <p>] [--pattern <g>] [--kind <k>] [--fuzzy] [--max-results N]\n", .{ s.red, s.reset, s.cyan, s.reset });
        return 1;
    };

    const spec = explore_mod.Explorer.SymbolSearchSpec{
        .name = n,
        .prefix = prefix,
        .pattern = pattern,
        .kind = kind_filter,
        .fuzzy = fuzzy,
        .max_results = @min(max_results, 200),
    };
    const results = explorer.searchSymbols(spec, a) catch return 1;

    if (json) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        buf.appendSlice(a, "{\"ok\":true,\"tool\":\"symbol\",\"count\":") catch {};
        jsonInt(a, &buf, results.len);
        buf.appendSlice(a, ",\"results\":[") catch {};
        for (results, 0..) |r, idx| {
            if (idx > 0) buf.append(a, ',') catch {};
            buf.append(a, '{') catch {};
            buf.appendSlice(a, "\"path\":") catch {};
            appendJsonStr(a, &buf, r.path);
            buf.appendSlice(a, ",\"line\":") catch {};
            jsonInt(a, &buf, r.symbol.line_start);
            buf.appendSlice(a, ",\"kind\":") catch {};
            appendJsonStr(a, &buf, @tagName(r.symbol.kind));
            buf.appendSlice(a, ",\"name\":") catch {};
            appendJsonStr(a, &buf, r.symbol.name);
            if (r.symbol.detail) |d| {
                buf.appendSlice(a, ",\"detail\":") catch {};
                appendJsonStr(a, &buf, d);
            }
            buf.append(a, '}') catch {};
        }
        buf.appendSlice(a, "]}\n") catch {};
        out.p("{s}", .{buf.items});
        return 0;
    }

    if (results.len == 0) {
        out.p("{s}\xe2\x9c\x97{s} not found: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, n, s.reset });
        return 1;
    }
    out.p("{s}\xe2\x9c\x93{s} {s}{d}{s} definition(s) for {s}{s}{s}\n", .{
        s.green, s.reset, s.bold, results.len, s.reset, s.bold, n, s.reset,
    });
    for (results) |r| {
        const kind = @tagName(r.symbol.kind);
        out.p("  {s}{s}{s}  {s}{s}{s}:{s}{d}{s}", .{
            s.kindColor(kind), kind, s.reset, s.dim, r.path, s.reset, s.cyan, r.symbol.line_start, s.reset,
        });
        if (body) {
            if (explorer.getSymbolBody(r.path, r.symbol.line_start, r.symbol.line_end, a) catch null) |bd| {
                out.p("\n{s}", .{bd});
            }
        }
        out.p("\n", .{});
    }
    return 0;
}

// ── callers / callees ─────────────────────────────────────────────────────

fn runNeighbors(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, json: bool, reverse: bool, args: []const []const u8, start: usize, req_id: ?[]const u8) u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    positionals(a, args, start, &pos);
    if (pos.items.len < 1) {
        out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] {s}<callers|callees>{s} {s}<name>{s}\n", .{ s.red, s.reset, s.cyan, s.reset, s.cyan, s.reset });
        return 1;
    }
    const name = pos.items[0];
    const stats = if (reverse)
        explorer.callersOfWithStats(name, a, 100) catch return 1
    else
        explorer.calleesOfWithStats(name, a, 100) catch return 1;
    const steps = stats.steps;
    const tool = if (reverse) "callers" else "callees";

    if (steps.len > 0) {
        if (json) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(a);
            buf.appendSlice(a, "{\"ok\":true,\"tool\":") catch {};
            appendJsonStr(a, &buf, tool);
            if (req_id) |rid| {
                buf.appendSlice(a, ",\"id\":") catch {};
                appendJsonStr(a, &buf, rid);
            }
            buf.appendSlice(a, ",\"ambiguous\":false,\"count\":") catch {};
            jsonInt(a, &buf, steps.len);
            buf.appendSlice(a, ",\"dropped_ambiguous_callers\":") catch {};
            jsonInt(a, &buf, stats.dropped_callers);
            buf.appendSlice(a, ",\"dropped_ambiguous_callees\":") catch {};
            jsonInt(a, &buf, stats.dropped_callees);
            buf.appendSlice(a, ",\"results\":[") catch {};
            for (steps, 0..) |st, idx| {
                if (idx > 0) buf.append(a, ',') catch {};
                buf.append(a, '{') catch {};
                buf.appendSlice(a, "\"path\":") catch {};
                appendJsonStr(a, &buf, st.path);
                buf.appendSlice(a, ",\"name\":") catch {};
                appendJsonStr(a, &buf, st.name);
                buf.appendSlice(a, ",\"line\":") catch {};
                jsonInt(a, &buf, st.line);
                buf.append(a, '}') catch {};
            }
            buf.appendSlice(a, "]}\n") catch {};
            out.p("{s}", .{buf.items});
            return 0;
        }
        out.p("{s}\xe2\x9c\x93{s} {s}{d}{s} {s}{s}{s} for {s}{s}{s}\n", .{
            s.green, s.reset, s.bold, steps.len, s.reset, s.bold, tool, s.reset, s.bold, name, s.reset,
        });
        for (steps) |st| {
            out.p("  {s}{s}{s}:{s}{d}{s}  {s}{s}{s}\n", .{
                s.cyan, st.path, s.reset, s.dim, st.line, s.reset, s.bold, st.name, s.reset,
            });
        }
        return 0;
    }

    // No resolved neighbors: distinguish an ambiguous name from a genuine miss
    // and surface the file-scoped candidate definitions (fail-closed, no merge).
    const spec = explore_mod.Explorer.SymbolSearchSpec{
        .name = name,
        .prefix = null,
        .pattern = null,
        .kind = null,
        .fuzzy = false,
        .max_results = 200,
    };
    const cands = explorer.searchSymbols(spec, a) catch return 1;
    var callable_count: usize = 0;
    for (cands) |r| {
        if (r.symbol.kind == .function or r.symbol.kind == .method) callable_count += 1;
    }

    if (json) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        buf.appendSlice(a, "{\"ok\":true,\"tool\":") catch {};
        appendJsonStr(a, &buf, tool);
        if (req_id) |rid| {
            buf.appendSlice(a, ",\"id\":") catch {};
            appendJsonStr(a, &buf, rid);
        }
        if (callable_count > 1) {
            buf.appendSlice(a, ",\"ambiguous\":true,\"count\":") catch {};
            jsonInt(a, &buf, callable_count);
            buf.appendSlice(a, ",\"results\":[") catch {};
            var first = true;
            for (cands) |r| {
                if (r.symbol.kind != .function and r.symbol.kind != .method) continue;
                if (!first) buf.append(a, ',') catch {};
                first = false;
                buf.append(a, '{') catch {};
                buf.appendSlice(a, "\"path\":") catch {};
                appendJsonStr(a, &buf, r.path);
                buf.appendSlice(a, ",\"name\":") catch {};
                appendJsonStr(a, &buf, r.symbol.name);
                buf.appendSlice(a, ",\"line\":") catch {};
                jsonInt(a, &buf, r.symbol.line_start);
                buf.appendSlice(a, ",\"kind\":") catch {};
                appendJsonStr(a, &buf, @tagName(r.symbol.kind));
                buf.append(a, '}') catch {};
            }
            buf.appendSlice(a, "]}\n") catch {};
        } else {
            buf.appendSlice(a, ",\"ambiguous\":false,\"count\":0,\"dropped_ambiguous_callers\":") catch {};
            jsonInt(a, &buf, stats.dropped_callers);
            buf.appendSlice(a, ",\"dropped_ambiguous_callees\":") catch {};
            jsonInt(a, &buf, stats.dropped_callees);
            buf.appendSlice(a, ",\"results\":[]}\n") catch {};
        }
        out.p("{s}", .{buf.items});
        return 0;
    }

    if (callable_count > 1) {
        out.p("{s}\xe2\x9c\x97{s} {s}{s}{s} is ambiguous ({s}{d}{s} definitions):\n", .{
            s.yellow, s.reset, s.bold, name, s.reset, s.bold, callable_count, s.reset,
        });
        for (cands) |r| {
            if (r.symbol.kind != .function and r.symbol.kind != .method) continue;
            out.p("  {s}{s}{s}:{s}{d}{s}  {s}{s}{s} {s}{s}{s}\n", .{
                s.cyan, r.path, s.reset, s.dim, r.symbol.line_start, s.reset, s.bold, r.symbol.name, s.reset, s.dim, @tagName(r.symbol.kind), s.reset,
            });
        }
        return 0;
    }
    const dropped = if (reverse) stats.dropped_callers else stats.dropped_callees;
    if (dropped > 0) {
        out.p("{s}\xe2\x9c\x93{s} 0 {s} for {s}{s}{s} ({d} ambiguous call sites detected)\n", .{
            s.dim, s.reset, tool, s.bold, name, s.reset, dropped,
        });
    } else {
        out.p("{s}\xe2\x9c\x97{s} no {s}{s}{s} for {s}{s}{s}\n", .{ s.yellow, s.reset, s.bold, tool, s.reset, s.bold, name, s.reset });
    }
    return 0;
}

fn runCombinedNeighbors(
    explorer: *Explorer,
    a: std.mem.Allocator,
    out: *Out,
    s: sty.Style,
    json: bool,
    args: []const []const u8,
    start: usize,
    req_id: ?[]const u8,
) u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    positionals(a, args, start, &pos);
    if (pos.items.len < 1) {
        if (json) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(a);
            buf.appendSlice(a, "{\"ok\":false") catch {};
            if (req_id) |rid| {
                buf.appendSlice(a, ",\"id\":") catch {};
                appendJsonStr(a, &buf, rid);
            }
            buf.appendSlice(a, ",\"error\":\"usage: codedb [root] neighbors <name>\"}\n") catch {};
            out.p("{s}", .{buf.items});
            return 1;
        }
        out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] neighbors {s}<name>{s}\n", .{ s.red, s.reset, s.cyan, s.reset });
        return 1;
    }
    const name = pos.items[0];
    const res = explorer.bothNeighborsOf(name, a, 100) catch return 1;

    if (json) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        buf.appendSlice(a, "{\"ok\":true,\"tool\":\"neighbors\"") catch {};
        if (req_id) |rid| {
            buf.appendSlice(a, ",\"id\":") catch {};
            appendJsonStr(a, &buf, rid);
        }
        buf.appendSlice(a, ",\"name\":") catch {};
        appendJsonStr(a, &buf, name);
        buf.appendSlice(a, ",\"symbol_exists\":") catch {};
        buf.appendSlice(a, if (res.symbol_exists) "true" else "false") catch {};

        if (res.ambiguous) {
            buf.appendSlice(a, ",\"ambiguous\":true,\"count\":") catch {};
            jsonInt(a, &buf, res.candidates.len);
            buf.appendSlice(a, ",\"results\":[") catch {};
            var first = true;
            for (res.candidates) |r| {
                if (!first) buf.append(a, ',') catch {};
                first = false;
                buf.append(a, '{') catch {};
                buf.appendSlice(a, "\"path\":") catch {};
                appendJsonStr(a, &buf, r.path);
                buf.appendSlice(a, ",\"name\":") catch {};
                appendJsonStr(a, &buf, r.symbol.name);
                buf.appendSlice(a, ",\"line\":") catch {};
                jsonInt(a, &buf, r.symbol.line_start);
                buf.appendSlice(a, ",\"kind\":") catch {};
                appendJsonStr(a, &buf, @tagName(r.symbol.kind));
                buf.append(a, '}') catch {};
            }
            buf.appendSlice(a, "]}\n") catch {};
            out.p("{s}", .{buf.items});
            return 0;
        }

        buf.appendSlice(a, ",\"ambiguous\":false") catch {};
        buf.appendSlice(a, ",\"dropped_ambiguous_callers\":") catch {};
        jsonInt(a, &buf, res.dropped_callers);
        buf.appendSlice(a, ",\"dropped_ambiguous_callees\":") catch {};
        jsonInt(a, &buf, res.dropped_callees);

        // callers
        buf.appendSlice(a, ",\"callers\":{\"count\":") catch {};
        jsonInt(a, &buf, res.callers.len);
        buf.appendSlice(a, ",\"results\":[") catch {};
        for (res.callers, 0..) |st, idx| {
            if (idx > 0) buf.append(a, ',') catch {};
            buf.append(a, '{') catch {};
            buf.appendSlice(a, "\"path\":") catch {};
            appendJsonStr(a, &buf, st.path);
            buf.appendSlice(a, ",\"name\":") catch {};
            appendJsonStr(a, &buf, st.name);
            buf.appendSlice(a, ",\"line\":") catch {};
            jsonInt(a, &buf, st.line);
            buf.append(a, '}') catch {};
        }
        buf.appendSlice(a, "]}") catch {};

        // callees
        buf.appendSlice(a, ",\"callees\":{\"count\":") catch {};
        jsonInt(a, &buf, res.callees.len);
        buf.appendSlice(a, ",\"results\":[") catch {};
        for (res.callees, 0..) |st, idx| {
            if (idx > 0) buf.append(a, ',') catch {};
            buf.append(a, '{') catch {};
            buf.appendSlice(a, "\"path\":") catch {};
            appendJsonStr(a, &buf, st.path);
            buf.appendSlice(a, ",\"name\":") catch {};
            appendJsonStr(a, &buf, st.name);
            buf.appendSlice(a, ",\"line\":") catch {};
            jsonInt(a, &buf, st.line);
            buf.append(a, '}') catch {};
        }
        buf.appendSlice(a, "]}}\n") catch {};
        out.p("{s}", .{buf.items});
        return 0;
    }

    if (!res.symbol_exists) {
        out.p("{s}\xe2\x9c\x97{s} Function or method \"{s}\" not found.\n", .{ s.red, s.reset, name });
        return 1;
    }

    if (res.ambiguous) {
        out.p("{s}\xe2\x9c\x97{s} {s}{s}{s} is ambiguous ({s}{d}{s} definitions):\n", .{
            s.yellow, s.reset, s.bold, name, s.reset, s.bold, res.candidates.len, s.reset,
        });
        for (res.candidates) |r| {
            const kind = @tagName(r.symbol.kind);
            out.p("  {s}{s}{s}  {s}{s}{s}:{s}{d}{s}\n", .{
                s.kindColor(kind), kind, s.reset, s.dim, r.path, s.reset, s.cyan, r.symbol.line_start, s.reset,
            });
        }
        return 0;
    }

    out.p("{s}\xe2\x9c\x93{s} neighbors for {s}{s}{s}:\n", .{ s.green, s.reset, s.bold, name, s.reset });
    if (res.callers.len > 0) {
        out.p("  callers ({d}):\n", .{res.callers.len});
        for (res.callers) |st| {
            out.p("    {s}{s}{s}:{s}{d}{s}  {s}{s}{s}\n", .{
                s.cyan, st.path, s.reset, s.dim, st.line, s.reset, s.bold, st.name, s.reset,
            });
        }
    } else if (res.dropped_callers > 0) {
        out.p("  callers: None (0 resolved; {d} ambiguous call sites detected)\n", .{res.dropped_callers});
    } else {
        out.p("  callers: None\n", .{});
    }

    if (res.callees.len > 0) {
        out.p("  callees ({d}):\n", .{res.callees.len});
        for (res.callees) |st| {
            out.p("    {s}{s}{s}:{s}{d}{s}  {s}{s}{s}\n", .{
                s.cyan, st.path, s.reset, s.dim, st.line, s.reset, s.bold, st.name, s.reset,
            });
        }
    } else if (res.dropped_callees > 0) {
        out.p("  callees: None (0 resolved; {d} ambiguous call sites detected)\n", .{res.dropped_callees});
    } else {
        out.p("  callees: None\n", .{});
    }
    return 0;
}

// ── callpath ──────────────────────────────────────────────────────────────

fn runCallpath(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, json: bool, args: []const []const u8, start: usize) u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    positionals(a, args, start, &pos);
    if (pos.items.len < 2) {
        out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] callpath {s}<from> <to>{s}\n", .{ s.red, s.reset, s.cyan, s.reset });
        return 1;
    }
    const from = pos.items[0];
    const to = pos.items[1];
    const path = explorer.findCallPath(from, to, a, 12) catch return 1;
    const steps = path orelse {
        if (json) {
            out.p("{{\"ok\":true,\"tool\":\"callpath\",\"count\":0,\"results\":[]}}\n", .{});
        } else {
            out.p("{s}\xe2\x9c\x97{s} no path from {s}{s}{s} to {s}{s}{s}\n", .{ s.red, s.reset, s.bold, from, s.reset, s.bold, to, s.reset });
        }
        return 0;
    };
    defer a.free(steps);

    if (json) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        buf.appendSlice(a, "{\"ok\":true,\"tool\":\"callpath\",\"count\":") catch {};
        jsonInt(a, &buf, steps.len);
        buf.appendSlice(a, ",\"results\":[") catch {};
        for (steps, 0..) |st, idx| {
            if (idx > 0) buf.append(a, ',') catch {};
            buf.append(a, '{') catch {};
            buf.appendSlice(a, "\"path\":") catch {};
            appendJsonStr(a, &buf, st.path);
            buf.appendSlice(a, ",\"name\":") catch {};
            appendJsonStr(a, &buf, st.name);
            buf.appendSlice(a, ",\"line\":") catch {};
            jsonInt(a, &buf, st.line);
            buf.append(a, '}') catch {};
        }
        buf.appendSlice(a, "]}\n") catch {};
        out.p("{s}", .{buf.items});
        return 0;
    }

    for (steps, 0..) |st, idx| {
        out.p("  {d}. {s}{s}{s}  {s}{s}{s}:{s}{d}{s}\n", .{
            idx + 1, s.bold, st.name, s.reset, s.cyan, st.path, s.reset, s.dim, st.line, s.reset,
        });
    }
    return 0;
}

// ── deps ──────────────────────────────────────────────────────────────────

fn runDeps(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, json: bool, args: []const []const u8, start: usize) u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    var depends_on = false;
    var i = start;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) continue;
        if (std.mem.eql(u8, arg, "--depends-on")) { depends_on = true; continue; }
        if (arg.len > 0 and arg[0] == '-') continue;
        pos.append(a, arg) catch {};
    }
    if (pos.items.len < 1) {
        out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] deps {s}<path>{s} [--depends-on]\n", .{ s.red, s.reset, s.cyan, s.reset });
        return 1;
    }
    const path = pos.items[0];
    const deps = if (depends_on)
        explorer.getTransitiveDependencies(path, a, null) catch return 1
    else
        explorer.getImportedBy(path, a) catch return 1;

    if (json) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        buf.appendSlice(a, "{\"ok\":true,\"tool\":\"deps\",\"count\":") catch {};
        jsonInt(a, &buf, deps.len);
        buf.appendSlice(a, ",\"results\":[") catch {};
        for (deps, 0..) |d, idx| {
            if (idx > 0) buf.append(a, ',') catch {};
            appendJsonStr(a, &buf, d);
        }
        buf.appendSlice(a, "]}\n") catch {};
        out.p("{s}", .{buf.items});
        return 0;
    }

    for (deps) |d| out.p("  {s}{s}{s}\n", .{ s.cyan, d, s.reset });
    return 0;
}

// ── search ────────────────────────────────────────────────────────────────

fn runSearch(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, args: []const []const u8, start: usize) u8 {
    const sa = parseSearchArgs(args, start) catch |e| {
        switch (e) {
            error.UnknownFlag => out.p("{s}\xe2\x9c\x97{s} unknown flag for {s}search{s}\n", .{ s.red, s.reset, s.bold, s.reset }),
            error.MissingMaxResults, error.BadMaxResults => out.p("{s}\xe2\x9c\x97{s} {s}--max-results{s} requires a positive integer\n", .{ s.red, s.reset, s.cyan, s.reset }),
            error.ExtraArg => out.p("{s}\xe2\x9c\x97{s} unexpected extra argument\n", .{ s.red, s.reset }),
            error.MissingQuery, error.EmptyQuery => out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] search {s}<query>{s}\n", .{ s.red, s.reset, s.cyan, s.reset }),
        }
        return 1;
    };
    const results = if (sa.use_regex)
        explorer.searchContentRegex(sa.query, a, sa.max_results) catch |err| {
            if (err == error.InvalidRegex) out.p("{s}\xe2\x9c\x97{s} invalid regex\n", .{ s.red, s.reset });
            return 1;
        }
    else
        explorer.searchContentAuto(sa.query, a, sa.max_results) catch return 1;

    if (results.len == 0) {
        out.p("{s}\xe2\x9c\x97{s} no results for {s}\"{s}\"{s}\n", .{ s.yellow, s.reset, s.bold, sa.query, s.reset });
        return 0;
    }
    out.p("{s}\xe2\x9c\x93{s} {s}{d}{s} results for {s}\"{s}\"{s}\n", .{
        s.green, s.reset, s.bold, results.len, s.reset, s.bold, sa.query, s.reset,
    });
    for (results) |r| {
        if (sa.paths_only) {
            out.p("  {s}{s}{s}:{s}{d}{s}\n", .{ s.cyan, r.path, s.reset, s.dim, r.line_num, s.reset });
        } else {
            out.p("  {s}{s}{s}:{s}{d}{s}  {s}\n", .{ s.cyan, r.path, s.reset, s.dim, r.line_num, s.reset, r.line_text });
        }
    }
    return 0;
}

// ── word ──────────────────────────────────────────────────────────────────

fn runWord(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, args: []const []const u8, start: usize) u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    positionals(a, args, start, &pos);
    if (pos.items.len < 1) {
        out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] word {s}<identifier>{s}\n", .{ s.red, s.reset, s.cyan, s.reset });
        return 1;
    }
    const word = pos.items[0];
    const hits = explorer.searchWord(word, a) catch return 1;
    if (hits.len == 0) {
        out.p("{s}\xe2\x9c\x97{s} no hits for {s}'{s}'{s}\n", .{ s.yellow, s.reset, s.bold, word, s.reset });
        return 0;
    }
    out.p("{s}\xe2\x9c\x93{s} {s}{d}{s} hits for {s}'{s}'{s}\n", .{
        s.green, s.reset, s.bold, hits.len, s.reset, s.bold, word, s.reset,
    });
    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();
    for (hits) |h| {
        out.p("  {s}{s}{s}:{s}{d}{s}\n", .{ s.cyan, explorer.word_index.hitPath(h), s.reset, s.dim, h.line_num, s.reset });
    }
    return 0;
}

// ── read ──────────────────────────────────────────────────────────────────

fn runRead(io: std.Io, explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, root: []const u8, args: []const []const u8, start: usize) u8 {
    var line_start: ?u32 = null;
    var line_end: ?u32 = null;
    var compact = false;
    var path_opt: ?[]const u8 = null;
    var arg_idx = start;
    while (args.len > arg_idx) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "--compact") or std.mem.eql(u8, arg, "-c")) {
            compact = true;
        } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--lines")) {
            if (arg_idx + 1 >= args.len) return 1;
            arg_idx += 1;
            const lr = parseLineRange(args[arg_idx]) catch return 1;
            line_start = lr.start;
            line_end = lr.end;
        } else if (arg.len > 0 and arg[0] == '-') {
            out.p("{s}\xe2\x9c\x97{s} unknown flag for read: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, arg, s.reset });
            return 1;
        } else if (path_opt == null) {
            path_opt = arg;
        } else {
            return 1;
        }
    }
    const path = path_opt orelse {
        out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] read {s}<path>{s}\n", .{ s.red, s.reset, s.cyan, s.reset });
        return 1;
    };
    if (watcher.isSensitivePath(path)) {
        out.p("{s}\xe2\x9c\x97{s} access to sensitive file blocked: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, path, s.reset });
        return 1;
    }
    const cached = explorer.getContent(path, a) catch null;
    const content_owned = if (cached) |c| c else blk: {
        var root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return 1;
        defer root_dir.close(io);
        break :blk root_dir.readFileAlloc(io, path, a, .limited(10 * 1024 * 1024)) catch return 1;
    };
    if (content_owned.len > 0 and std.mem.indexOfScalar(u8, content_owned[0..@min(content_owned.len, 8 * 1024)], 0) != null) {
        out.p("{s}\xe2\x9c\x97{s} binary file\n", .{ s.yellow, s.reset });
        return 0;
    }
    const lang = explore_mod.detectLanguage(path);
    if (line_start != null or line_end != null or compact) {
        const line_start_val: u32 = line_start orelse 1;
        const end: u32 = line_end orelse std.math.maxInt(u32);
        const extracted = explore_mod.extractLines(content_owned, line_start_val, end, true, compact, lang, a) catch return 1;
        out.p("{s}", .{extracted});
    } else {
        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content_owned, '\n');
        while (lines.next()) |line| {
            line_num += 1;
            out.p("{d:>5} | {s}\n", .{ line_num, line });
        }
    }
    return 0;
}

// ── hot ───────────────────────────────────────────────────────────────────

fn runHot(explorer: *Explorer, store: *Store, a: std.mem.Allocator, out: *Out, s: sty.Style) u8 {
    const hot = explorer.getHotFiles(store, a, 10) catch return 1;
    out.p("{s}\xe2\x9c\x93{s} {s}recently modified{s}\n", .{ s.green, s.reset, s.bold, s.reset });
    for (hot, 1..) |path, i| {
        out.p("  {s}{d}{s}  {s}{s}{s}\n", .{ s.dim, i, s.reset, s.cyan, path, s.reset });
    }
    return 0;
}

// ── status ────────────────────────────────────────────────────────────────

fn runStatus(explorer: *Explorer, store: *Store, out: *Out, s: sty.Style, root: []const u8) u8 {
    store.mu.lock();
    const file_count = store.files.count();
    const seq = store.seq;
    store.mu.unlock();
    explorer.mu.lockShared();
    const outline_count = explorer.outlines.count();
    explorer.mu.unlockShared();
    out.p("{s}\xe2\x9c\x93{s} {s}codedb-core{s}  {s}{s}{s}\n", .{ s.green, s.reset, s.bold, s.reset, s.cyan, root, s.reset });
    out.p("  {s}files{s}     {s}{d}{s} indexed\n", .{ s.dim, s.reset, s.bold, file_count, s.reset });
    out.p("  {s}seq{s}       {s}{d}{s}\n", .{ s.dim, s.reset, s.bold, seq, s.reset });
    out.p("  {s}outlines{s}  {s}{d}{s}\n", .{ s.dim, s.reset, s.bold, outline_count, s.reset });
    return 0;
}

// ── glob / ls / file ──────────────────────────────────────────────────────

fn runGlob(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, args: []const []const u8, start: usize) u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    positionals(a, args, start, &pos);
    if (pos.items.len < 1) {
        out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] glob {s}<pattern>{s}\n", .{ s.red, s.reset, s.cyan, s.reset });
        return 1;
    }
    const matches = explorer.globPaths(a, pos.items[0], 5000) catch return 1;
    for (matches) |m| out.p("  {s}{s}{s}\n", .{ s.cyan, m, s.reset });
    return 0;
}

fn runLs(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, args: []const []const u8, start: usize) u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    positionals(a, args, start, &pos);
    const prefix = if (pos.items.len > 0) pos.items[0] else "";
    const entries = explorer.lsDir(a, prefix) catch return 1;
    for (entries) |e| {
        if (e.is_dir) {
            out.p("  {s}{s}{s}/\n", .{ s.bold, e.name, s.reset });
        } else {
            out.p("  {s}{s}{s}  ({s}, {d}L, {d} sym)\n", .{
                s.cyan, e.name, s.reset, @tagName(e.language), e.line_count, e.sym_count,
            });
        }
    }
    return 0;
}

fn runFile(explorer: *Explorer, a: std.mem.Allocator, out: *Out, s: sty.Style, args: []const []const u8, start: usize) u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(a);
    positionals(a, args, start, &pos);
    if (pos.items.len < 1) {
        out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] file {s}<fuzzy-name>{s}\n", .{ s.red, s.reset, s.cyan, s.reset });
        return 1;
    }
    const matches = explorer.fuzzyFindFiles(pos.items[0], a, 20) catch return 1;
    for (matches) |m| {
        out.p("  {s}{s}{s}\n", .{ s.cyan, m.path, s.reset });
    }
    return 0;
}

// ── serve (resident stdio mode) ──────────────────────────────────────────

const windows_job = if (builtin.os.tag == .windows) struct {
    const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: i64 = 0,
        PerJobUserTimeLimit: i64 = 0,
        LimitFlags: u32 = 0x2000, // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        MinimumWorkingSetSize: usize = 0,
        MaximumWorkingSetSize: usize = 0,
        ActiveProcessLimit: u32 = 0,
        Affinity: usize = 0,
        PriorityClass: u32 = 0,
        SchedulingClass: u32 = 0,
    };
    const IO_COUNTERS = extern struct {
        ReadOperationCount: u64 = 0,
        WriteOperationCount: u64 = 0,
        OtherOperationCount: u64 = 0,
        ReadTransferCount: u64 = 0,
        WriteTransferCount: u64 = 0,
        OtherTransferCount: u64 = 0,
    };
    const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
        IoInfo: IO_COUNTERS = .{},
        ProcessMemoryLimit: usize = 0,
        JobMemoryLimit: usize = 0,
        PeakProcessMemoryUsed: usize = 0,
        PeakJobMemoryUsed: usize = 0,
    };
    extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*anyopaque, lpName: ?[*:0]const u16) callconv(.winapi) ?std.os.windows.HANDLE;
    extern "kernel32" fn SetInformationJobObject(hJob: std.os.windows.HANDLE, JobObjectInformationClass: u32, lpJobObjectInformation: *const anyopaque, cbJobObjectInformationLength: u32) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(hJob: std.os.windows.HANDLE, hProcess: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) std.os.windows.HANDLE;

    fn setup() void {
        const job = CreateJobObjectW(null, null) orelse return;
        var info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION{};
        _ = SetInformationJobObject(job, 9, &info, @sizeOf(@TypeOf(info)));
        _ = AssignProcessToJobObject(job, GetCurrentProcess());
    }
} else struct {
    fn setup() void {}
};

const StdinLineReader = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,

    fn nextLine(self: *StdinLineReader, allocator: std.mem.Allocator, out_buf: *std.ArrayList(u8)) bool {
        out_buf.clearRetainingCapacity();
        while (true) {
            if (self.pos >= self.len) {
                const n = cio.read(0, &self.buf, self.buf.len);
                if (n <= 0) {
                    return out_buf.items.len > 0;
                }
                self.len = @intCast(n);
                self.pos = 0;
            }
            while (self.pos < self.len) {
                const b = self.buf[self.pos];
                self.pos += 1;
                if (b == '\n') return true;
                if (b != '\r') out_buf.append(allocator, b) catch return false;
            }
        }
    }
};

fn splitCommandLine(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;
        if (line[i] == '"' or line[i] == '\'') {
            const quote = line[i];
            i += 1;
            const start = i;
            while (i < line.len and line[i] != quote) i += 1;
            try tokens.append(a, line[start..i]);
            if (i < line.len) i += 1;
        } else {
            const start = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
            try tokens.append(a, line[start..i]);
        }
    }
    return tokens.toOwnedSlice(a);
}

fn runServe(
    io: std.Io,
    allocator: std.mem.Allocator,
    explorer: *Explorer,
    store: *Store,
    root: []const u8,
    out: *Out,
    s: sty.Style,
) u8 {
    windows_job.setup();

    // Emit initial ready handshake
    var r_buf: std.ArrayList(u8) = .empty;
    defer r_buf.deinit(allocator);
    r_buf.appendSlice(allocator, "{\"ok\":true,\"status\":\"ready\",\"root\":") catch {};
    appendJsonStr(allocator, &r_buf, root);
    r_buf.appendSlice(allocator, "}\n") catch {};
    out.p("{s}", .{r_buf.items});
    out.flush();

    var reader = StdinLineReader{};
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    while (reader.nextLine(allocator, &line_buf)) {
        const line = std.mem.trim(u8, line_buf.items, " \t\r\n");
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit")) break;
        if (std.mem.eql(u8, line, "ping")) {
            out.p("{{\"ok\":true,\"status\":\"pong\"}}\n", .{});
            out.flush();
            continue;
        }
        if (std.mem.eql(u8, line, "reload") or (line.len >= 2 and line[0] == '{' and std.mem.indexOf(u8, line, "\"reload\"") != null)) {
            watcher.initialScan(io, store, explorer, root, allocator, true) catch {};
            out.p("{{\"ok\":true,\"status\":\"reloaded\"}}\n", .{});
            out.flush();
            continue;
        }

        // Each query runs in its own ArenaAllocator, torn down immediately
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        var req_id: ?[]const u8 = null;
        var sub_cmd: []const u8 = "";
        var sub_args: []const []const u8 = &.{};

        if (line[0] == '{') {
            const JsonReq = struct {
                id: ?std.json.Value = null,
                cmd: ?[]const u8 = null,
                args: ?[][]const u8 = null,
                name: ?[]const u8 = null,
            };
            const parsed = std.json.parseFromSlice(JsonReq, a, line, .{ .ignore_unknown_fields = true }) catch null;
            if (parsed) |p| {
                if (p.value.id) |id_val| {
                    switch (id_val) {
                        .string => |s_val| req_id = s_val,
                        .integer => |i_val| {
                            var b: [32]u8 = undefined;
                            req_id = std.fmt.bufPrint(&b, "{d}", .{i_val}) catch null;
                            if (req_id) |rid| req_id = a.dupe(u8, rid) catch null;
                        },
                        else => {},
                    }
                }
                sub_cmd = p.value.cmd orelse "neighbors";
                if (p.value.args) |eargs| {
                    sub_args = eargs;
                } else if (p.value.name) |ename| {
                    var s_list: std.ArrayList([]const u8) = .empty;
                    s_list.append(a, ename) catch {};
                    s_list.append(a, "--json") catch {};
                    sub_args = s_list.toOwnedSlice(a) catch &.{};
                }
            } else {
                sub_cmd = "";
            }
        } else {
            const tokens = splitCommandLine(a, line) catch null;
            if (tokens) |t| {
                if (t.len > 0) {
                    sub_cmd = t[0];
                    sub_args = t[1..];
                }
            }
        }

        if (sub_cmd.len == 0) {
            out.p("{{\"ok\":false,\"error\":\"empty or unparseable command\"}}\n", .{});
            out.flush();
            continue;
        }

        const is_json = hasJsonFlag(sub_args, 0) or (line[0] == '{');

        if (std.mem.eql(u8, sub_cmd, "neighbors")) {
            _ = runCombinedNeighbors(explorer, a, out, s, is_json, sub_args, 0, req_id);
        } else if (std.mem.eql(u8, sub_cmd, "callers")) {
            _ = runNeighbors(explorer, a, out, s, is_json, true, sub_args, 0, req_id);
        } else if (std.mem.eql(u8, sub_cmd, "callees")) {
            _ = runNeighbors(explorer, a, out, s, is_json, false, sub_args, 0, req_id);
        } else if (std.mem.eql(u8, sub_cmd, "ping")) {
            var p_buf: std.ArrayList(u8) = .empty;
            defer p_buf.deinit(a);
            p_buf.appendSlice(a, "{\"ok\":true") catch {};
            if (req_id) |rid| {
                p_buf.appendSlice(a, ",\"id\":") catch {};
                appendJsonStr(a, &p_buf, rid);
            }
            p_buf.appendSlice(a, ",\"query\":\"ping\",\"status\":\"pong\"}\n") catch {};
            out.p("{s}", .{p_buf.items});
        } else if (std.mem.eql(u8, sub_cmd, "status") and is_json) {
            store.mu.lock();
            const file_count = store.files.count();
            const seq = store.seq;
            store.mu.unlock();
            explorer.mu.lockShared();
            const outline_count = explorer.outlines.count();
            explorer.mu.unlockShared();
            var p_buf: std.ArrayList(u8) = .empty;
            defer p_buf.deinit(a);
            p_buf.appendSlice(a, "{\"ok\":true") catch {};
            if (req_id) |rid| {
                p_buf.appendSlice(a, ",\"id\":") catch {};
                appendJsonStr(a, &p_buf, rid);
            }
            p_buf.appendSlice(a, ",\"query\":\"status\",\"files\":") catch {};
            jsonInt(a, &p_buf, file_count);
            p_buf.appendSlice(a, ",\"seq\":") catch {};
            jsonInt(a, &p_buf, seq);
            p_buf.appendSlice(a, ",\"outlines\":") catch {};
            jsonInt(a, &p_buf, outline_count);
            p_buf.appendSlice(a, "}\n") catch {};
            out.p("{s}", .{p_buf.items});
        } else if (cli_args.cliIsQueryCmd(sub_cmd)) {
            var query_args: std.ArrayList([]const u8) = .empty;
            defer query_args.deinit(a);
            for (sub_args) |sa| query_args.append(a, sa) catch {};
            if (is_json and !hasJsonFlag(sub_args, 0)) {
                query_args.append(a, "--json") catch {};
            }
            _ = runQuery(io, allocator, explorer, store, root, sub_cmd, query_args.items, 0, out, s);
        } else {
            var p_buf: std.ArrayList(u8) = .empty;
            defer p_buf.deinit(a);
            p_buf.appendSlice(a, "{\"ok\":false") catch {};
            if (req_id) |rid| {
                p_buf.appendSlice(a, ",\"id\":") catch {};
                appendJsonStr(a, &p_buf, rid);
            }
            p_buf.appendSlice(a, ",\"error\":\"unknown command\"}\n") catch {};
            out.p("{s}", .{p_buf.items});
        }
        out.flush();
    }
    return 0;
}
