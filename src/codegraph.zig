//! codegraph.zig — deterministic resolved call graph (Phase 1 foundation).
//!
//! codedb already has the two ingredients a precise call graph needs: the parser
//! emits function symbols with line ranges, and `symbol_index` maps a name to its
//! definition sites. What was missing is the middle step — walking call sites and
//! resolving them — which this module provides, deterministically and without an
//! LLM. (Mirrors graphify's `extract.py` walk_calls + symbol-resolution facts, but
//! in codedb's fast/local model.)
//!
//! The graph is the foundation for: centrality-boosted ranking, edge-aware
//! context expansion, and community detection. It is always an ADDITIVE signal —
//! never a filter — so a misresolved edge can never drop a real result.

const std = @import("std");

pub const NodeId = u32;

/// A resolved call edge `from` → `to`. `weight` splits 1.0 across the candidate
/// definitions of an ambiguous callee name (1 candidate → 1.0), so a name that
/// resolves cleanly contributes full weight and an ambiguous one is discounted.
pub const Edge = struct {
    from: NodeId,
    to: NodeId,
    weight: f32,
};

pub const FuncInput = struct {
    id: NodeId,
    /// The function's body text (caller slices it from content via line ranges).
    body: []const u8,
};

/// True for identifiers that precede `(` but are language keywords / control flow,
/// not callees — so `if (`, `for (`, `while (`, `catch (`, `return (` etc. are not
/// counted as calls. Deliberately a cross-language superset (codedb indexes ~40
/// languages); over-filtering a rare real call only loses an additive boost.
fn isCallKeyword(name: []const u8) bool {
    const kws = [_][]const u8{
        "if",     "else",   "for",     "while",  "switch", "return",  "catch",
        "try",    "defer",  "errdefer", "and",   "or",     "orelse",  "sizeof",
        "typeof", "do",     "case",    "when",   "match",  "with",    "in",
        "not",    "is",     "await",   "yield",  "throw",  "new",     "delete",
        "fn",     "func",   "function", "def",   "class",  "struct",  "enum",
        "union",  "const",  "var",     "let",    "static", "assert",  "where",
        "select", "from",   "foreach", "using",  "unless", "until",   "elif",
    };
    for (kws) |kw| if (std.mem.eql(u8, name, kw)) return true;
    return false;
}

inline fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
inline fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Extract deduped callee identifier names that appear as call sites (`ident(`)
/// in a function body. The identifier immediately preceding an unmatched `(` is
/// the candidate callee (`obj.foo(` yields `foo`; `a[i](` yields nothing). Items
/// are slices into `body`; caller frees the returned array.
pub fn extractCallees(allocator: std.mem.Allocator, body: []const u8) ![][]const u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    const TemplateFrame = struct {
        in_interp: bool = false,
        interp_depth: usize = 0,
    };
    var t_stack: [16]TemplateFrame = undefined;
    var t_depth: usize = 0;

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        // Skip line comments, block comments, and string/char literals so an identifier
        // mentioned only inside one is not mistaken for a call site (#548 family).
        if (c == '/' and i + 1 < body.len and body[i + 1] == '/') {
            i += 2;
            while (i < body.len and body[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < body.len and body[i + 1] == '*') {
            i += 2;
            while (i + 1 < body.len and !(body[i] == '*' and body[i + 1] == '/')) i += 1;
            i += 1; // land on '/' of '*/'; the loop's i += 1 then moves past it
            continue;
        }
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < body.len and body[i] != c) {
                if (body[i] == '\\' and i + 1 < body.len) i += 1; // skip an escaped char
                i += 1;
            }
            continue;
        }

        // Inside a template literal's literal text span (not currently in an ${...} interpolation)
        if (t_depth > 0 and !t_stack[t_depth - 1].in_interp) {
            if (c == '\\') {
                if (i + 1 < body.len) i += 1; // skip escaped char (e.g. \` or \${)
                continue;
            }
            if (c == '`') {
                t_depth -= 1; // template ended
                continue;
            }
            if (c == '$' and i + 1 < body.len and body[i + 1] == '{') {
                i += 1; // advance to '{'
                t_stack[t_depth - 1].in_interp = true;
                t_stack[t_depth - 1].interp_depth = 0;
                continue;
            }
            continue; // skip literal characters in template text
        }

        // Outside template, or inside `${...}` interpolation:
        if (c == '`') {
            if (t_depth < t_stack.len) {
                t_stack[t_depth] = .{ .in_interp = false, .interp_depth = 0 };
                t_depth += 1;
            }
            continue;
        }

        if (t_depth > 0 and t_stack[t_depth - 1].in_interp) {
            if (c == '{') {
                t_stack[t_depth - 1].interp_depth += 1;
            } else if (c == '}') {
                if (t_stack[t_depth - 1].interp_depth == 0) {
                    t_stack[t_depth - 1].in_interp = false;
                    continue;
                } else {
                    t_stack[t_depth - 1].interp_depth -= 1;
                }
            }
        }

        if (c != '(') continue;
        // Skip spaces/tabs between the identifier and the '('.
        var end = i;
        while (end > 0 and (body[end - 1] == ' ' or body[end - 1] == '\t')) end -= 1;
        // Walk back over identifier characters.
        var start = end;
        while (start > 0 and isIdentChar(body[start - 1])) start -= 1;
        if (start == end) continue; // nothing before '(' (e.g. `(expr)`, `)(`)
        const name = body[start..end];
        if (!isIdentStart(name[0])) continue; // started on a digit → not an ident
        if (isCallKeyword(name)) continue;
        const g = try seen.getOrPut(name);
        if (!g.found_existing) try out.append(allocator, name);
    }
    return out.toOwnedSlice(allocator);
}

/// Build resolved call edges for a set of functions. `resolve` maps a callee name
/// to the node ids of its candidate definitions (codedb's `symbol_index`). Edge
/// weight is split across candidates; self-edges are dropped unless `allow_self`.
pub fn buildEdges(
    allocator: std.mem.Allocator,
    funcs: []const FuncInput,
    resolve: *const std.StringHashMap([]const NodeId),
    allow_self: bool,
) !std.ArrayList(Edge) {
    var edges: std.ArrayList(Edge) = .empty;
    errdefer edges.deinit(allocator);
    for (funcs) |f| {
        const callees = try extractCallees(allocator, f.body);
        defer allocator.free(callees);
        for (callees) |name| {
            const cands = resolve.get(name) orelse continue;
            if (cands.len == 0) continue;
            const w: f32 = 1.0 / @as(f32, @floatFromInt(cands.len));
            for (cands) |to| {
                if (!allow_self and to == f.id) continue;
                try edges.append(allocator, .{ .from = f.id, .to = to, .weight = w });
            }
        }
    }
    return edges;
}

/// Weighted in-degree centrality: how much a node is called by others. This is
/// the "god node" signal (graphify's most-connected nodes) and the additive
/// boost we fold into ranking in Phase 2.
pub fn inDegreeCentrality(allocator: std.mem.Allocator, edges: []const Edge, n_nodes: usize) ![]f32 {
    const c = try allocator.alloc(f32, n_nodes);
    @memset(c, 0);
    for (edges) |e| {
        if (e.to < n_nodes) c[e.to] += e.weight;
    }
    return c;
}

/// Iterative PageRank over a directed call graph. `damping` is typically 0.85;
/// `iterations` is usually 20–50. Dangling nodes (no outgoing edges) leak rank
/// uniformly. Returns per-node scores (caller frees).
pub fn pageRank(
    allocator: std.mem.Allocator,
    edges: []const Edge,
    n_nodes: usize,
    damping: f32,
    iterations: usize,
) ![]f32 {
    if (n_nodes == 0) return try allocator.alloc(f32, 0);

    const rank = try allocator.alloc(f32, n_nodes);
    errdefer allocator.free(rank);
    const scratch = try allocator.alloc(f32, n_nodes);
    defer allocator.free(scratch);

    const init: f32 = 1.0 / @as(f32, @floatFromInt(n_nodes));
    @memset(rank, init);

    const out_weight = try allocator.alloc(f32, n_nodes);
    defer allocator.free(out_weight);
    @memset(out_weight, 0);
    for (edges) |e| {
        if (e.from < n_nodes) out_weight[e.from] += e.weight;
    }

    const leak: f32 = (1.0 - damping) / @as(f32, @floatFromInt(n_nodes));

    for (0..iterations) |_| {
        @memset(scratch, leak);

        var dangling: f32 = 0;
        for (0..n_nodes) |i| {
            if (out_weight[i] == 0) dangling += rank[i];
        }
        if (dangling > 0) {
            const share = damping * dangling / @as(f32, @floatFromInt(n_nodes));
            for (scratch) |*s| s.* += share;
        }

        for (edges) |e| {
            if (e.from >= n_nodes or e.to >= n_nodes) continue;
            const ow = out_weight[e.from];
            if (ow > 0) scratch[e.to] += damping * rank[e.from] * (e.weight / ow);
        }

        @memcpy(rank, scratch);
    }

    return rank;
}

/// Build a forward adjacency list (caller owns returned slice and inner lists).
pub fn buildAdjacency(
    allocator: std.mem.Allocator,
    edges: []const Edge,
    n_nodes: usize,
) ![]std.ArrayList(NodeId) {
    const adj = try allocator.alloc(std.ArrayList(NodeId), n_nodes);
    errdefer {
        for (adj) |*list| list.deinit(allocator);
        allocator.free(adj);
    }
    for (adj) |*list| list.* = .empty;
    for (edges) |e| {
        if (e.from < n_nodes and e.to < n_nodes) {
            try adj[e.from].append(allocator, e.to);
        }
    }
    return adj;
}

pub fn freeAdjacency(allocator: std.mem.Allocator, adj: []std.ArrayList(NodeId)) void {
    for (adj) |*list| list.deinit(allocator);
    allocator.free(adj);
}

/// Shortest call chain from any `from_ids` node to any node in `to_ids`.
/// Returns owned node-id path (inclusive) or null when unreachable within
/// `max_hops` (default unlimited when max_hops == 0).
pub fn shortestCallPath(
    allocator: std.mem.Allocator,
    adj: []const std.ArrayList(NodeId),
    n_nodes: usize,
    from_ids: []const NodeId,
    to_ids: []const NodeId,
    max_hops: usize,
) !?[]NodeId {
    if (n_nodes == 0 or from_ids.len == 0 or to_ids.len == 0) return null;

    var to_set = std.AutoHashMap(NodeId, void).init(allocator);
    defer to_set.deinit();
    for (to_ids) |id| {
        if (id < n_nodes) try to_set.put(id, {});
    }
    if (to_set.count() == 0) return null;

    for (from_ids) |id| {
        if (id < n_nodes and to_set.contains(id)) {
            const path = try allocator.alloc(NodeId, 1);
            path[0] = id;
            return path;
        }
    }

    var queue: std.ArrayList(NodeId) = .empty;
    defer queue.deinit(allocator);
    var visited = std.AutoHashMap(NodeId, void).init(allocator);
    defer visited.deinit();
    const parent = try allocator.alloc(?NodeId, n_nodes);
    defer allocator.free(parent);
    @memset(parent, null);

    for (from_ids) |id| {
        if (id >= n_nodes) continue;
        try queue.append(allocator, id);
        try visited.put(id, {});
    }

    var head: usize = 0;
    var depth: usize = 0;
    var level_end = queue.items.len;

    while (head < queue.items.len) {
        if (head == level_end) {
            depth += 1;
            if (max_hops > 0 and depth > max_hops) return null;
            level_end = queue.items.len;
        }

        const cur = queue.items[head];
        head += 1;

        if (depth > 0 and to_set.contains(cur)) {
            var len: usize = 0;
            var n: ?NodeId = cur;
            while (n) |v| : (n = parent[v]) len += 1;

            const path = try allocator.alloc(NodeId, len);
            var idx = len;
            n = cur;
            while (n) |v| {
                idx -= 1;
                path[idx] = v;
                n = parent[v];
            }
            return path;
        }

        if (cur >= adj.len) continue;
        for (adj[cur].items) |next| {
            if (next >= n_nodes or visited.contains(next)) continue;
            try visited.put(next, {});
            parent[next] = cur;
            try queue.append(allocator, next);
        }
    }

    return null;
}

test "extractCallees template literal and comments" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 1. Literal text call-shaped fragment ignored
    {
        const body = "const msg = `run validate() before commit`;";
        const callees = try extractCallees(alloc, body);
        defer alloc.free(callees);
        try testing.expectEqual(@as(usize, 0), callees.len);
    }

    // 2. Real call inside interpolation
    {
        const body = "const msg = `Hello ${targetCall()} world`;";
        const callees = try extractCallees(alloc, body);
        defer alloc.free(callees);
        try testing.expectEqual(@as(usize, 1), callees.len);
        try testing.expectEqualStrings("targetCall", callees[0]);
    }

    // 3. Multiline with both literal text and real interpolation
    {
        const body =
            \\function render() {
            \\    const doc = `
            \\      This is notACall() here.
            \\      ${realCall(123)}
            \\      and neither is thisOtherNotCall()
            \\    `;
            \\    return doc;
            \\}
        ;
        const callees = try extractCallees(alloc, body);
        defer alloc.free(callees);
        try testing.expectEqual(@as(usize, 1), callees.len);
        try testing.expectEqualStrings("realCall", callees[0]);
    }

    // 4. Nested interpolation
    {
        const body = "const str = `outer ${a ? `${nestedCall()}` : otherCall()} end`;";
        const callees = try extractCallees(alloc, body);
        defer alloc.free(callees);
        try testing.expectEqual(@as(usize, 2), callees.len);
        var has_nested = false;
        var has_other = false;
        for (callees) |c| {
            if (std.mem.eql(u8, c, "nestedCall")) has_nested = true;
            if (std.mem.eql(u8, c, "otherCall")) has_other = true;
        }
        try testing.expect(has_nested and has_other);
    }

    // 5. Object literal inside interpolation
    {
        const body = "const val = `val: ${ { x: objCall() } }`;";
        const callees = try extractCallees(alloc, body);
        defer alloc.free(callees);
        try testing.expectEqual(@as(usize, 1), callees.len);
        try testing.expectEqualStrings("objCall", callees[0]);
    }

    // 6. Escapes
    {
        const body = "const esc = `\\${fakeCall()} and \\` stillNotCall()`;";
        const callees = try extractCallees(alloc, body);
        defer alloc.free(callees);
        try testing.expectEqual(@as(usize, 0), callees.len);
    }
}

