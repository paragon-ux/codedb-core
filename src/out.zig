const std = @import("std");
const cio = @import("cio.zig");
const sty = @import("style.zig");

pub const Out = struct {
    file: cio.File,
    alloc: std.mem.Allocator,
    buf: [65536]u8 = undefined,
    used: usize = 0,
    // When set, flush() appends here instead of writing to `file`. Lets a warm
    // daemon capture a command's full rendered output (run via runQuery) and frame
    // it back to a CLI client over a socket — reusing the exact rendering the cold
    // CLI uses. null for the normal stdout path.
    sink: ?*std.ArrayList(u8) = null,

    pub fn p(self: *Out, comptime fmt: []const u8, args: anytype) void {
        // Fast path: format directly into the remaining buffer window.
        const remaining = self.buf[self.used..];
        if (std.fmt.bufPrint(remaining, fmt, args)) |s| {
            self.used += s.len;
            return;
        } else |_| {}
        // Either doesn't fit OR remaining is too small. Flush, retry from start.
        self.flush();
        if (std.fmt.bufPrint(&self.buf, fmt, args)) |s| {
            self.used = s.len;
            return;
        } else |_| {}
        // Single message larger than 64KB — fall back to one-shot heap alloc.
        const big = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(big);
        if (self.sink) |snk| {
            snk.appendSlice(self.alloc, big) catch {};
        } else {
            self.file.writeAll(big) catch {};
        }
    }

    pub fn flush(self: *Out) void {
        if (self.used == 0) return;
        if (self.sink) |snk| {
            snk.appendSlice(self.alloc, self.buf[0..self.used]) catch {};
        } else {
            self.file.writeAll(self.buf[0..self.used]) catch {};
        }
        self.used = 0;
    }

    /// Print + flush + exit. `std.process.exit(_)` skips the deferred
    /// `out.flush()`, which used to silently swallow usage and error
    /// messages on any failure path — `codedb` with no args printed
    /// nothing and just exited 1 (#504). Use this anywhere we'd
    /// otherwise call exit() directly after writing user-facing output.
    pub fn exitWithFlush(self: *Out, code: u8) noreturn {
        self.flush();
        std.process.exit(code);
    }
};

pub fn printUsage(out: *Out, s: sty.Style) void {
    out.p("{s}codedb{s}  deterministic structural code intelligence\n", .{ s.bold, s.reset });
    out.p("{s}usage:{s} codedb [root] <command> [args...]\n\n", .{ s.dim, s.reset });
    out.p("{s}commands:{s}\n", .{ s.dim, s.reset });
    out.p("  {s}tree{s}          show file tree with language and symbol counts\n", .{ s.cyan, s.reset });
    out.p("  {s}outline{s} <p>   list all symbols in a file\n", .{ s.cyan, s.reset });
    out.p("  {s}find{s} <n>      find where a symbol is defined\n", .{ s.cyan, s.reset });
    out.p("  {s}symbol{s} <n>    find symbol definitions (ranked)\n", .{ s.cyan, s.reset });
    out.p("  {s}callers{s} <n>   resolved callers of a symbol (fail-closed)\n", .{ s.cyan, s.reset });
    out.p("  {s}callees{s} <n>   resolved callees of a symbol (fail-closed)\n", .{ s.cyan, s.reset });
    out.p("  {s}callpath{s} a b  shortest resolved call chain\n", .{ s.cyan, s.reset });
    out.p("  {s}deps{s} <p>      dependency graph (--depends-on)\n", .{ s.cyan, s.reset });
    out.p("  {s}search{s} <q>    full-text search (trigram, case-insensitive)\n", .{ s.cyan, s.reset });
    out.p("  {s}word{s} <id>     exact word lookup via inverted index\n", .{ s.cyan, s.reset });
    out.p("  {s}read{s} <p>      file contents (-L FROM-TO, --compact)\n", .{ s.cyan, s.reset });
    out.p("  {s}glob{s} <pat>    match indexed paths by glob\n", .{ s.cyan, s.reset });
    out.p("  {s}ls{s} [p]        list a directory's indexed children\n", .{ s.cyan, s.reset });
    out.p("  {s}hot{s}           recently modified files\n", .{ s.cyan, s.reset });
    out.p("  {s}status{s}        index size and store seq\n", .{ s.cyan, s.reset });
    out.p("\n{s}options:{s}\n", .{ s.dim, s.reset });
    out.p("  {s}--json{s}          emit machine-readable JSON (all query commands)\n", .{ s.cyan, s.reset });
    out.p("  {s}--config-file <p>{s} load config overrides (default: ./.codedbrc)\n\n", .{ s.cyan, s.reset });
    out.p("If root is omitted, uses current working directory.\n", .{});
    out.p("exit codes: 0 = success, 1 = usage error or operational failure.\n", .{});
}
