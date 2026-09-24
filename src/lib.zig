// codedb-core — Zig module for deterministic structural code intelligence.
//
// Lexical-only fork of justrach/codedb. Provides symbol indexing, dependency
// graphs, version tracking, trigram/word search indexes, a resolved call graph,
// and file watching. No embeddings, telemetry, MCP server, or cloud surface.
//
// Usage as a dependency:
//   const codedb = @import("codedb");
//   var store = codedb.Store.init(allocator);
//   var explorer = codedb.Explorer.init(allocator);
//   try codedb.watcher.initialScan(&store, &explorer, root, allocator);

pub const Store = @import("store.zig").Store;
pub const ChangeEntry = @import("store.zig").ChangeEntry;

pub const Config = @import("config.zig").Config;

pub const Explorer = @import("explore.zig").Explorer;
pub const FileOutline = @import("explore.zig").FileOutline;
pub const Symbol = @import("explore.zig").Symbol;
pub const SymbolKind = @import("explore.zig").SymbolKind;
pub const SymbolResult = @import("explore.zig").SymbolResult;
pub const SearchResult = @import("explore.zig").SearchResult;
pub const Language = @import("explore.zig").Language;
pub const DependencyGraph = @import("explore.zig").DependencyGraph;
pub const SymbolLocation = @import("explore.zig").SymbolLocation;

pub const WordIndex = @import("index.zig").WordIndex;
pub const TrigramIndex = @import("index.zig").TrigramIndex;
pub const WordHit = @import("index.zig").WordHit;
pub const WordTokenizer = @import("index.zig").WordTokenizer;

pub const Version = @import("version.zig").Version;
pub const FileVersions = @import("version.zig").FileVersions;
pub const Op = @import("version.zig").Op;

pub const watcher = @import("watcher.zig");
