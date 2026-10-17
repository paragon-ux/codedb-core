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
    defer {
        for (steps) |s| {
            testing.allocator.free(s.path);
            testing.allocator.free(s.name);
        }
        testing.allocator.free(steps);
    }
    const Step = struct { name: []const u8, line: u32 };
    var got: std.ArrayList(Step) = .empty;
    defer got.deinit(testing.allocator);
    for (steps) |s| {
        try testing.expectEqualStrings("src/use.ts", s.path);
        try got.append(testing.allocator, .{ .name = s.name, .line = s.line });
    }
    std.mem.sort(Step, got.items, {}, struct {
        fn lt(_: void, x: Step, y: Step) bool {
            return x.line < y.line;
        }
    }.lt);
    const want = [_]Step{
        .{ .name = "viaFunction", .line = 3 },
        .{ .name = "viaArrow", .line = 7 },
        .{ .name = "handler", .line = 13 },
        .{ .name = "run", .line = 19 },
        .{ .name = "start", .line = 23 },
    };
    errdefer for (got.items) |g| std.debug.print("  caller {s}:{d}\n", .{ g.name, g.line });
    try testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| {
        try testing.expectEqualStrings(w.name, g.name);
        try testing.expectEqual(w.line, g.line);
    }
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
    try testing.expectEqual(@as(usize, 2), ex.call_graph.?.node_name.len);
    try testing.expectEqual(@as(usize, 0), ex.call_graph.?.edges.len);
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
