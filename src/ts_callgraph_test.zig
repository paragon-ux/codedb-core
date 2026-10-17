// TypeScript/JavaScript callables: class methods, function-valued object
// properties and arrow consts become `.method`/`.function` symbols, so the
// call graph has a caller for the calls inside them.

const std = @import("std");
const testing = std.testing;
const explore = @import("explore.zig");
const Explorer = explore.Explorer;
const SymbolKind = explore.SymbolKind;

const Callable = struct {
    name: []const u8,
    kind: SymbolKind,
    start: u32,
    end: u32,
};

/// The outline's `.function`/`.method` symbols are exactly `want`, in order.
fn expectCallables(path: []const u8, src: []const u8, want: []const Callable) !void {
    var parsed = try Explorer.parseContentForIndexing(testing.allocator, path, src);
    defer parsed.deinit();
    var got: std.ArrayList(Callable) = .empty;
    defer got.deinit(testing.allocator);
    for (parsed.outline.symbols.items) |s| {
        if (s.kind != .function and s.kind != .method) continue;
        try got.append(testing.allocator, .{ .name = s.name, .kind = s.kind, .start = s.line_start, .end = s.line_end });
    }
    errdefer for (got.items) |g| std.debug.print("  got {s} {t} {d}..{d}\n", .{ g.name, g.kind, g.start, g.end });
    try testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| {
        try testing.expectEqualStrings(w.name, g.name);
        try testing.expectEqual(w.kind, g.kind);
        try testing.expectEqual(w.start, g.start);
        try testing.expectEqual(w.end, g.end);
    }
}

/// The symbol named `name` on `line` has `kind`.
fn expectKind(path: []const u8, src: []const u8, name: []const u8, line: u32, kind: SymbolKind) !void {
    var parsed = try Explorer.parseContentForIndexing(testing.allocator, path, src);
    defer parsed.deinit();
    for (parsed.outline.symbols.items) |s| {
        if (s.line_start == line and std.mem.eql(u8, s.name, name)) {
            try testing.expectEqual(kind, s.kind);
            return;
        }
    }
    std.debug.print("no symbol {s} on line {d}\n", .{ name, line });
    return error.TestUnexpectedResult;
}

const lib_ts =
    \\export function target(): number {
    \\  return 1;
    \\}
    \\
;

const use_ts =
    \\import { target } from "./lib";
    \\
    \\export function viaFunction(): number {
    \\  return target();
    \\}
    \\
    \\export const viaArrow = (): number => {
    \\  return target();
    \\};
    \\
    \\export const tool = {
    \\  name: "demo",
    \\  handler: async (args: unknown) => {
    \\    return target();
    \\  },
    \\};
    \\
    \\export class Svc {
    \\  run(): number {
    \\    return target();
    \\  }
    \\
    \\  async start(options: { paths?: string[] } = {}): Promise<number> {
    \\    return target();
    \\  }
    \\}
    \\
;

test "ts call graph: callers in arrow consts, object handlers and class methods resolve" {
    var ex = Explorer.init(testing.allocator, 16);
    defer ex.deinit();
    try ex.indexFile("src/lib.ts", lib_ts);
    try ex.indexFile("src/use.ts", use_ts);

    const steps = try ex.callersOf("target", testing.allocator, 50);
    defer freeSteps(steps);
    const Step = struct { name: []const u8, qualified: []const u8, kind: explore.CallNodeKind, line: u32 };
    var got: std.ArrayList(Step) = .empty;
    defer got.deinit(testing.allocator);
    for (steps) |s| {
        try testing.expectEqualStrings("src/use.ts", s.path);
        try got.append(testing.allocator, .{ .name = s.name, .qualified = s.qualified, .kind = s.kind, .line = s.line });
    }
    std.mem.sort(Step, got.items, {}, struct {
        fn lt(_: void, x: Step, y: Step) bool {
            return x.line < y.line;
        }
    }.lt);
    const want = [_]Step{
        .{ .name = "viaFunction", .qualified = "viaFunction", .kind = .function, .line = 3 },
        .{ .name = "viaArrow", .qualified = "viaArrow", .kind = .function, .line = 7 },
        .{ .name = "handler", .qualified = "tool.handler", .kind = .method, .line = 13 },
        .{ .name = "run", .qualified = "Svc.run", .kind = .method, .line = 19 },
        .{ .name = "start", .qualified = "Svc.start", .kind = .method, .line = 23 },
    };
    errdefer for (got.items) |g| std.debug.print("  caller {s} {s} {t}:{d}\n", .{ g.name, g.qualified, g.kind, g.line });
    try testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| {
        try testing.expectEqualStrings(w.name, g.name);
        try testing.expectEqualStrings(w.qualified, g.qualified);
        try testing.expectEqual(w.kind, g.kind);
        try testing.expectEqual(w.line, g.line);
    }
}

fn freeSteps(steps: []const explore.CallPathStep) void {
    for (steps) |s| {
        testing.allocator.free(s.path);
        testing.allocator.free(s.name);
        testing.allocator.free(s.qualified);
    }
    testing.allocator.free(steps);
}

test "ts call graph: a qualified name resolves where the bare name is ambiguous" {
    const src =
        \\export class A {
        \\  start(): number {
        \\    return helper();
        \\  }
        \\}
        \\export class B {
        \\  start(): number {
        \\    return 2;
        \\  }
        \\}
        \\export function helper(): number {
        \\  return 1;
        \\}
        \\export function boot(a: A): number {
        \\  return a.start();
        \\}
        \\
    ;
    var ex = Explorer.init(testing.allocator, 16);
    defer ex.deinit();
    try ex.indexFile("src/ab.ts", src);

    // Bare `start` names two nodes: fail closed, as before.
    const bare = try ex.calleesOf("start", testing.allocator, 50);
    defer freeSteps(bare);
    try testing.expectEqual(@as(usize, 0), bare.len);

    const callees = try ex.calleesOf("A.start", testing.allocator, 50);
    defer freeSteps(callees);
    try testing.expectEqual(@as(usize, 1), callees.len);
    try testing.expectEqualStrings("helper", callees[0].name);
    try testing.expectEqual(explore.CallNodeKind.function, callees[0].kind);

    // `a.start()` keeps both methods as candidates, so it stays ambiguous.
    const callers = try ex.callersOf("A.start", testing.allocator, 50);
    defer freeSteps(callers);
    try testing.expectEqual(@as(usize, 0), callers.len);

    const missing = try ex.callersOf("C.start", testing.allocator, 50);
    defer freeSteps(missing);
    try testing.expectEqual(@as(usize, 0), missing.len);

    var both = try ex.bothNeighborsOf("B.start", testing.allocator, 50);
    defer {
        freeSteps(both.callers);
        freeSteps(both.callees);
    }
    try testing.expect(both.symbol_exists and !both.ambiguous);
    _ = &both;
}

fn freeCandidates(cands: []const Explorer.ScoredSymbolResult) void {
    for (cands) |r| Explorer.freeScoredSymbol(testing.allocator, r);
    testing.allocator.free(cands);
}

test "ts call graph: an ambiguous qualified name lists every candidate and emits no edge" {
    const src =
        \\export class Shapes {
        \\  get size(): number {
        \\    return count();
        \\  }
        \\  set size(n: number) {
        \\    store(n);
        \\  }
        \\}
        \\export function count(): number {
        \\  return 1;
        \\}
        \\export function store(n: number): void {
        \\  return;
        \\}
        \\export function measure(s: Shapes): number {
        \\  return s.size();
        \\}
        \\
    ;
    var ex = Explorer.init(testing.allocator, 16);
    defer ex.deinit();
    try ex.indexFile("src/shapes.ts", src);

    // The getter and setter are both `Shapes.size`: the same ambiguity
    // response a bare name gets, with both candidates.
    const both = try ex.bothNeighborsOf("Shapes.size", testing.allocator, 50);
    defer freeCandidates(both.candidates);
    try testing.expect(both.symbol_exists and both.ambiguous);
    try testing.expectEqual(@as(usize, 0), both.callers.len);
    try testing.expectEqual(@as(usize, 0), both.callees.len);
    try testing.expectEqual(@as(usize, 2), both.candidates.len);
    for (both.candidates, [_]u32{ 2, 5 }) |r, line| {
        try testing.expectEqualStrings("src/shapes.ts", r.path);
        try testing.expectEqualStrings("size", r.symbol.name);
        try testing.expectEqualStrings("Shapes.size", r.symbol.qualified.?);
        try testing.expectEqual(SymbolKind.method, r.symbol.kind);
        try testing.expectEqual(line, r.symbol.line_start);
    }

    // callers/callees fail closed, and nothing resolves to either accessor.
    const callers = try ex.callersOf("Shapes.size", testing.allocator, 50);
    defer freeSteps(callers);
    try testing.expectEqual(@as(usize, 0), callers.len);
    const callees = try ex.calleesOf("Shapes.size", testing.allocator, 50);
    defer freeSteps(callees);
    try testing.expectEqual(@as(usize, 0), callees.len);
    const cg = ex.call_graph.?;
    for (cg.edges) |e| try testing.expect(!std.mem.eql(u8, cg.node_qualified[e.to], "Shapes.size"));

    // The bare name's candidates carry their qualified names too.
    const bare = try ex.bothNeighborsOf("size", testing.allocator, 50);
    defer freeCandidates(bare.candidates);
    try testing.expect(bare.ambiguous);
    try testing.expectEqual(@as(usize, 2), bare.candidates.len);
    for (bare.candidates) |r| try testing.expectEqualStrings("Shapes.size", r.symbol.qualified.?);

    // A qualified name that names nothing is a miss, not an ambiguity.
    const missing = try ex.bothNeighborsOf("Shapes.area", testing.allocator, 50);
    defer freeCandidates(missing.candidates);
    try testing.expect(!missing.symbol_exists and !missing.ambiguous);
    try testing.expectEqual(@as(usize, 0), missing.candidates.len);
}

test "ts outline: qualified names for class and object-literal members" {
    const src =
        \\export class Svc {
        \\  handlers = {
        \\    onData: (d: string) => {
        \\      work(d);
        \\    },
        \\  };
        \\  start() {
        \\    work(1);
        \\  }
        \\}
        \\export const tools = {
        \\  handler: async () => {
        \\    work(2);
        \\  },
        \\  nested: {
        \\    inner() {
        \\      work(3);
        \\    },
        \\  },
        \\};
        \\export default {
        \\  setup() {
        \\    work(4);
        \\  },
        \\};
        \\register({
        \\  loose() {
        \\    work(5);
        \\  },
        \\});
        \\const Named = class {
        \\  run() {
        \\    work(6);
        \\  }
        \\};
        \\
    ;
    var parsed = try Explorer.parseContentForIndexing(testing.allocator, "src/q.ts", src);
    defer parsed.deinit();
    const Want = struct { name: []const u8, line: u32, qualified: ?[]const u8 };
    const want = [_]Want{
        .{ .name = "onData", .line = 3, .qualified = "Svc.handlers.onData" },
        .{ .name = "start", .line = 7, .qualified = "Svc.start" },
        .{ .name = "handler", .line = 12, .qualified = "tools.handler" },
        .{ .name = "inner", .line = 16, .qualified = "tools.nested.inner" },
        .{ .name = "setup", .line = 22, .qualified = "default.setup" },
        .{ .name = "loose", .line = 27, .qualified = null },
        .{ .name = "run", .line = 32, .qualified = "Named.run" },
    };
    for (want) |w| {
        const sym = for (parsed.outline.symbols.items) |s| {
            if (s.line_start == w.line and std.mem.eql(u8, s.name, w.name)) break s;
        } else {
            std.debug.print("no symbol {s} on line {d}\n", .{ w.name, w.line });
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(SymbolKind.method, sym.kind);
        if (w.qualified) |q| {
            try testing.expectEqualStrings(q, sym.qualified orelse "");
        } else try testing.expect(sym.qualified == null);
    }
}

test "ts call graph: a module node owns top-level calls and anonymous callbacks" {
    const lib =
        \\export function target(): number {
        \\  return 1;
        \\}
        \\export function other(): number {
        \\  return 2;
        \\}
        \\export class Daemon {
        \\  start(): void {}
        \\}
        \\
    ;
    const app =
        \\import { target, other, Daemon } from "./lib";
        \\
        \\target();
        \\test("runs", async () => {
        \\  await target();
        \\});
        \\process.once("exit", () => target());
        \\
        \\export function named(): number {
        \\  return other();
        \\}
        \\start();
        \\new Daemon().start();
        \\
    ;
    var ex = Explorer.init(testing.allocator, 16);
    defer ex.deinit();
    try ex.indexFile("src/lib.ts", lib);
    try ex.indexFile("src/app.ts", app);

    const callers = try ex.callersOf("target", testing.allocator, 50);
    defer freeSteps(callers);
    try testing.expectEqual(@as(usize, 1), callers.len);
    try testing.expectEqualStrings("src/app.ts", callers[0].path);
    try testing.expectEqualStrings("<module>", callers[0].name);
    try testing.expectEqualStrings("<module>", callers[0].qualified);
    try testing.expectEqual(explore.CallNodeKind.module, callers[0].kind);
    try testing.expectEqual(@as(u32, 1), callers[0].line);

    // `other()` belongs to `named`, not to the module as well.
    const other_callers = try ex.callersOf("other", testing.allocator, 50);
    defer freeSteps(other_callers);
    try testing.expectEqual(@as(usize, 1), other_callers.len);
    try testing.expectEqualStrings("named", other_callers[0].name);

    // The bare-call rule holds for module code: only `new Daemon().start()`.
    const start_callers = try ex.callersOf("Daemon.start", testing.allocator, 50);
    defer freeSteps(start_callers);
    try testing.expectEqual(@as(usize, 1), start_callers.len);
    try testing.expectEqual(explore.CallNodeKind.module, start_callers[0].kind);

    // Nothing resolves to a module node.
    const cg = ex.call_graph.?;
    var modules: usize = 0;
    for (cg.node_kind) |k| modules += @intFromBool(k == .module);
    try testing.expectEqual(@as(usize, 2), modules);
    for (cg.edges) |e| try testing.expect(cg.node_kind[e.to] != .module);
}

test "ts call graph: a method's own signature is not a call to its namesake" {
    // Each body starts at its declaration line; `start(` there must not
    // resolve to the other class's `start` (same file, unique once self is
    // excluded) and make an edge.
    const src =
        \\export class A {
        \\  start(): number {
        \\    return 1;
        \\  }
        \\}
        \\export class B {
        \\  start(): number {
        \\    return 2;
        \\  }
        \\}
        \\
    ;
    var ex = Explorer.init(testing.allocator, 16);
    defer ex.deinit();
    try ex.indexFile("src/ab.ts", src);
    const steps = try ex.callersOf("start", testing.allocator, 50); // builds the graph
    defer testing.allocator.free(steps);
    // Two methods and the file's module node.
    try testing.expectEqual(@as(usize, 3), ex.call_graph.?.node_name.len);
    try testing.expectEqual(@as(usize, 0), ex.call_graph.?.edges.len);
}

const Node = struct { path: []const u8, name: []const u8, line: u32 };

/// Index `files`, build the call graph, and report whether it has `from -> to`.
fn graphHasEdge(files: []const [2][]const u8, from: Node, to: Node) !bool {
    var ex = Explorer.init(testing.allocator, 16);
    defer ex.deinit();
    for (files) |f| try ex.indexFile(f[0], f[1]);
    const steps = try ex.callersOf("__build_graph__", testing.allocator, 1);
    testing.allocator.free(steps);
    const cg = ex.call_graph.?;
    for (cg.edges) |e| {
        if (nodeIs(cg, e.from, from) and nodeIs(cg, e.to, to)) return true;
    }
    return false;
}

fn nodeIs(cg: explore.CallGraph, id: u32, n: Node) bool {
    return cg.node_line[id] == n.line and std.mem.eql(u8, cg.node_path[id], n.path) and std.mem.eql(u8, cg.node_name[id], n.name);
}

const daemon_ts =
    \\export class WaymarkDaemon {
    \\  async start(): Promise<boolean> {
    \\    return true;
    \\  }
    \\}
    \\
;

const stub_ts =
    \\import { WaymarkDaemon } from "./daemon";
    \\
    \\export async function withDaemonStub(start: () => Promise<boolean>): Promise<boolean> {
    \\  return start();
    \\}
    \\
    \\export async function launch(daemon: WaymarkDaemon): Promise<boolean> {
    \\  return daemon.start();
    \\}
    \\
;

test "ts call graph: a bare call never resolves to a method" {
    // `start()` calls the parameter; only `daemon.start()` can reach the method.
    const files = [_][2][]const u8{ .{ "src/daemon.ts", daemon_ts }, .{ "src/stub.ts", stub_ts } };
    const method: Node = .{ .path = "src/daemon.ts", .name = "start", .line = 2 };
    try testing.expect(!try graphHasEdge(&files, .{ .path = "src/stub.ts", .name = "withDaemonStub", .line = 3 }, method));
    try testing.expect(try graphHasEdge(&files, .{ .path = "src/stub.ts", .name = "launch", .line = 7 }, method));
}

test "ts call graph: this.method() resolves to the same file's method" {
    const a_ts =
        \\export class A {
        \\  start(): number {
        \\    return 1;
        \\  }
        \\  run(): number {
        \\    return this.start();
        \\  }
        \\}
        \\
    ;
    const b_ts =
        \\export class B {
        \\  start(): number {
        \\    return 2;
        \\  }
        \\}
        \\
    ;
    const files = [_][2][]const u8{ .{ "src/a.ts", a_ts }, .{ "src/b.ts", b_ts } };
    const run: Node = .{ .path = "src/a.ts", .name = "run", .line = 5 };
    try testing.expect(try graphHasEdge(&files, run, .{ .path = "src/a.ts", .name = "start", .line = 2 }));
    try testing.expect(!try graphHasEdge(&files, run, .{ .path = "src/b.ts", .name = "start", .line = 2 }));
}

test "ts call graph: a bare call reaches the free function beside a same-name method" {
    // Before, `stop()` had two same-file candidates and emitted nothing.
    const src =
        \\export function stop(): void {}
        \\export class S {
        \\  stop(): void {
        \\    return;
        \\  }
        \\}
        \\export function shutdown(): void {
        \\  stop();
        \\}
        \\
    ;
    const files = [_][2][]const u8{.{ "src/stop.ts", src }};
    const shutdown: Node = .{ .path = "src/stop.ts", .name = "shutdown", .line = 7 };
    try testing.expect(try graphHasEdge(&files, shutdown, .{ .path = "src/stop.ts", .name = "stop", .line = 1 }));
    try testing.expect(!try graphHasEdge(&files, shutdown, .{ .path = "src/stop.ts", .name = "stop", .line = 3 }));
}

test "ts outline: the repro's callables and their kinds" {
    try expectCallables("src/use.ts", use_ts, &.{
        .{ .name = "viaFunction", .kind = .function, .start = 3, .end = 5 },
        .{ .name = "viaArrow", .kind = .function, .start = 7, .end = 9 },
        .{ .name = "handler", .kind = .method, .start = 13, .end = 15 },
        .{ .name = "run", .kind = .method, .start = 19, .end = 21 },
        .{ .name = "start", .kind = .method, .start = 23, .end = 25 },
    });
    try expectKind("src/use.ts", use_ts, "tool", 11, .constant);
    try expectKind("src/use.ts", use_ts, "Svc", 18, .class_def);
}

test "ts outline: class member shapes" {
    const src =
        \\export abstract class Shapes<T> extends Base implements Thing {
        \\  private readonly onExit = () => this.stop();
        \\  static count = 0;
        \\  #secret = 1;
        \\  handler = async (args: unknown) => {
        \\    work(args);
        \\  };
        \\  typed: Handler = ({ a, b }: Args) => {
        \\    work(a);
        \\  };
        \\
        \\  constructor(private readonly root: string) {
        \\    super();
        \\  }
        \\
        \\  @Decorated()
        \\  async start(options: { paths?: string[]; signal?: AbortSignal } = {}): Promise<boolean> {
        \\    return true;
        \\  }
        \\
        \\  static create(): Shapes<number> {
        \\    return new Shapes("x");
        \\  }
        \\
        \\  get size(): number {
        \\    return 1;
        \\  }
        \\
        \\  set size(v: number) {
        \\    this.v = v;
        \\  }
        \\
        \\  *items(): Generator<number> {
        \\    yield 1;
        \\  }
        \\
        \\  async *stream() {
        \\    yield 2;
        \\  }
        \\
        \\  #hidden(): void {
        \\    work(1);
        \\  }
        \\
        \\  protected multi(
        \\    a: string,
        \\    b: number,
        \\  ): void {
        \\    work(a);
        \\  }
        \\
        \\  overload(a: string): void;
        \\  overload(a: number): void;
        \\  overload(a: unknown): void {
        \\    work(a);
        \\  }
        \\
        \\  abstract todo(): void;
        \\
        \\  parse(type: string) {
        \\    return type;
        \\  }
        \\}
        \\
    ;
    try expectCallables("src/shapes.ts", src, &.{
        .{ .name = "onExit", .kind = .method, .start = 2, .end = 2 },
        .{ .name = "handler", .kind = .method, .start = 5, .end = 7 },
        .{ .name = "typed", .kind = .method, .start = 8, .end = 10 },
        .{ .name = "constructor", .kind = .method, .start = 12, .end = 14 },
        .{ .name = "start", .kind = .method, .start = 17, .end = 19 },
        .{ .name = "create", .kind = .method, .start = 21, .end = 23 },
        .{ .name = "size", .kind = .method, .start = 25, .end = 27 },
        .{ .name = "size", .kind = .method, .start = 29, .end = 31 },
        .{ .name = "items", .kind = .method, .start = 33, .end = 35 },
        .{ .name = "stream", .kind = .method, .start = 37, .end = 39 },
        .{ .name = "hidden", .kind = .method, .start = 41, .end = 43 },
        .{ .name = "multi", .kind = .method, .start = 45, .end = 50 },
        .{ .name = "overload", .kind = .method, .start = 54, .end = 56 },
        .{ .name = "parse", .kind = .method, .start = 60, .end = 62 },
    });
    try expectKind("src/shapes.ts", src, "Shapes", 1, .class_def);
}

test "ts outline: function-valued object properties and shorthand methods" {
    const src =
        \\export const tools: ToolHandler = {
        \\  name: "demo",
        \\  handler: async (args: unknown) => {
        \\    work(args);
        \\  },
        \\  plain(args: unknown) {
        \\    work(args);
        \\  },
        \\  async shorthand(a: string): Promise<void> {
        \\    work(a);
        \\  },
        \\  legacy: function (a: string) {
        \\    work(a);
        \\  },
        \\  short: (a: string) => work(a),
        \\  multiLine: async ({
        \\    a,
        \\    b,
        \\  }: Args) => {
        \\    work(a);
        \\  },
        \\  nested: {
        \\    inner(x: number) {
        \\      work(x);
        \\    },
        \\  },
        \\};
        \\
    ;
    try expectCallables("src/tools.ts", src, &.{
        .{ .name = "handler", .kind = .method, .start = 3, .end = 5 },
        .{ .name = "plain", .kind = .method, .start = 6, .end = 8 },
        .{ .name = "shorthand", .kind = .method, .start = 9, .end = 11 },
        .{ .name = "legacy", .kind = .method, .start = 12, .end = 14 },
        .{ .name = "short", .kind = .method, .start = 15, .end = 15 },
        .{ .name = "multiLine", .kind = .method, .start = 16, .end = 21 },
        .{ .name = "inner", .kind = .method, .start = 23, .end = 25 },
    });
    try expectKind("src/tools.ts", src, "tools", 1, .constant);
}

test "ts outline: arrow-function consts" {
    const src =
        \\export const a = () => {
        \\  work(1);
        \\};
        \\export const b = async (x: number): Promise<void> => {
        \\  work(x);
        \\};
        \\const c = <T,>(x: T) => x;
        \\let d = x => work(x);
        \\export const e = (
        \\  x: number,
        \\) => {
        \\  work(x);
        \\};
        \\const f = (1 + 2) * 3;
        \\const g = (await load()) as Thing;
        \\export const h: Handler = async (event) => {
        \\  work(event);
        \\};
        \\const i = function named() {
        \\  work(2);
        \\};
        \\const j = () =>
        \\  work(3);
        \\const k = (x: number) => ({
        \\  value: work(x),
        \\});
        \\
    ;
    try expectCallables("src/consts.ts", src, &.{
        .{ .name = "a", .kind = .function, .start = 1, .end = 3 },
        .{ .name = "b", .kind = .function, .start = 4, .end = 6 },
        .{ .name = "c", .kind = .function, .start = 7, .end = 7 },
        .{ .name = "d", .kind = .function, .start = 8, .end = 8 },
        .{ .name = "e", .kind = .function, .start = 9, .end = 13 },
        .{ .name = "h", .kind = .function, .start = 16, .end = 18 },
        .{ .name = "i", .kind = .function, .start = 19, .end = 21 },
        .{ .name = "j", .kind = .function, .start = 22, .end = 23 },
        .{ .name = "k", .kind = .function, .start = 24, .end = 26 },
    });
    try expectKind("src/consts.ts", src, "f", 14, .constant);
    try expectKind("src/consts.ts", src, "g", 15, .constant);
}

test "ts outline: callables nested in a function body stay out of the graph" {
    const src =
        \\export function outer() {
        \\  const inner = () => {
        \\    work(1);
        \\  };
        \\  const obj = {
        \\    handler: () => {
        \\      work(2);
        \\    },
        \\  };
        \\  return inner;
        \\}
        \\export class K {
        \\  run() {
        \\    const helper = () => work(3);
        \\    return { go() { return 1; } };
        \\  }
        \\}
        \\describe("suite", () => {
        \\  const setup = () => {
        \\    work(4);
        \\  };
        \\});
        \\
    ;
    try expectCallables("src/nested.ts", src, &.{
        .{ .name = "outer", .kind = .function, .start = 1, .end = 11 },
        .{ .name = "run", .kind = .method, .start = 13, .end = 16 },
        // Inside an anonymous callback there is no enclosing node.
        .{ .name = "setup", .kind = .function, .start = 19, .end = 21 },
    });
    try expectKind("src/nested.ts", src, "inner", 2, .constant);
    try expectKind("src/nested.ts", src, "helper", 14, .constant);
}

test "ts outline: control flow and calls are not methods" {
    const src =
        \\describe("x", () => {
        \\  if (ready) {
        \\    run(1);
        \\  }
        \\  for (const y of list) {
        \\    step(y);
        \\  }
        \\  while (busy) {
        \\    tick();
        \\  }
        \\  switch (mode) {
        \\    case 1: {
        \\      go();
        \\    }
        \\  }
        \\  try {
        \\    risky();
        \\  } catch (e) {
        \\    recover(e);
        \\  }
        \\  with (scope) {
        \\    use(scope);
        \\  }
        \\  doThing(a,
        \\    b);
        \\  wrap({
        \\    inner: 1,
        \\  });
        \\  useEffect(() => {
        \\    tick();
        \\  });
        \\  return finish(x);
        \\});
        \\
    ;
    try expectCallables("src/flow.ts", src, &.{});
}

test "ts outline: interface and type-literal members are not methods" {
    const src =
        \\export interface Tool {
        \\  handler(args: unknown): Promise<void>;
        \\  run: (x: number) => void;
        \\  build: (x: number) => {
        \\    a: number;
        \\  };
        \\}
        \\export type Opts = {
        \\  onData: (d: string) => void;
        \\  parse(type: string): number;
        \\};
        \\export function take(opts: {
        \\  cb: (x: number) => void;
        \\  done(): void;
        \\}) {
        \\  return opts;
        \\}
        \\export const typed: {
        \\  go: () => void;
        \\} = makeTyped();
        \\declare module "x" {
        \\  export const helper: () => void;
        \\}
        \\
    ;
    try expectCallables("src/types.ts", src, &.{
        .{ .name = "take", .kind = .function, .start = 12, .end = 17 },
    });
}

test "ts outline: strings, templates, regexes and comments do not shift scopes" {
    const src =
        \\export class T {
        \\  render() {
        \\    return `
        \\      <div>{
        \\      ${this.items.map((i) => `<li>${i}</li>`).join("")}
        \\    `;
        \\  }
        \\
        \\  after = () => {
        \\    work(1);
        \\  };
        \\}
        \\export class R {
        \\  scan() {
        \\    const re = /[{(]/g;
        \\    const s = "{ ( '";
        \\    const t = '{';
        \\    // {
        \\    /* { */ const u = 1; /* {
        \\    } */
        \\    return re.test(s + t) ? 1 : 2 / 3;
        \\  }
        \\
        \\  after = () => {
        \\    work(1);
        \\  };
        \\}
        \\
    ;
    try expectCallables("src/masked.ts", src, &.{
        .{ .name = "render", .kind = .method, .start = 2, .end = 7 },
        .{ .name = "after", .kind = .method, .start = 9, .end = 11 },
        .{ .name = "scan", .kind = .method, .start = 14, .end = 22 },
        .{ .name = "after", .kind = .method, .start = 24, .end = 26 },
    });
}

test "ts outline: a keyword inside a string does not hide the next member" {
    // The keyword sniff still records `throw` as a .function (unchanged),
    // with a span reaching into `next`; it must not count as enclosing it.
    const src =
        \\export class E {
        \\  check() {
        \\    throw new Error("x is not a function or class");
        \\  }
        \\
        \\  next() {
        \\    work(1);
        \\  }
        \\}
        \\
    ;
    try expectCallables("src/strings.ts", src, &.{
        .{ .name = "check", .kind = .method, .start = 2, .end = 4 },
        .{ .name = "throw", .kind = .function, .start = 3, .end = 8 },
        .{ .name = "next", .kind = .method, .start = 6, .end = 8 },
    });
}

test "js outline: object shorthand methods and class methods" {
    const src =
        \\module.exports = {
        \\  start(opts) {
        \\    work(opts);
        \\  },
        \\};
        \\class Queue {
        \\  push(item) {
        \\    work(item);
        \\  }
        \\}
        \\
    ;
    try expectCallables("lib/queue.js", src, &.{
        .{ .name = "start", .kind = .method, .start = 2, .end = 4 },
        .{ .name = "push", .kind = .method, .start = 7, .end = 9 },
    });
}
