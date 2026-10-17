# @paragon-ux/codedb-core

## 2.0.2

- **`codedb --version` reports this package's version.** Through 2.0.1 it printed `codedb 0.2.5828`, a constant inherited from upstream `justrach/codedb`. `build.zig` now reads `version` from `package.json` and builds it into the binary, so the two can't drift; a missing or non-semver version fails the build. Queries and output are otherwise unchanged.
- **Tests**: `zig build test` builds the CLI and checks that `--version`, `-v`, `version`, and `<root> --version` all print `codedb <package.json version>`.
- **Release check**: `.github/workflows/release.yml` fails if the smoke-run `codedb-linux-x64` or `codedb-darwin-arm64` binary's `--version` doesn't match `package.json`.
- `build.zig.zon` lists `package.json` in `paths`, since `build.zig` now reads it.

## 2.0.1

- **Prebuilt binaries are executable again.** In 1.1.0 and 2.0.0, the macOS and Linux binaries in `dist/` shipped without the executable bit, so running `bin/codedb` directly on those platforms failed with a permission error. Hosts that `chmod` the binary before running it, such as waymark-engine, were unaffected. The binaries and code are otherwise unchanged from 2.0.0.
- **Released from CI.** `.github/workflows/release.yml` now builds all five binaries (macOS on macOS runners), checks the tarball, and publishes with npm Trusted Publishing and provenance whenever a `v*` tag is pushed. Run it manually with `dry_run` to rehearse a release without publishing.

## 2.0.0

**Breaking:** the config file is now `.codedb-corerc`, and `.codedbrc` is no longer read automatically. If you tuned `.codedbrc`, rename it or pass `--config-file .codedbrc`. Queries and output are unchanged.

### Own on-disk names; never touch upstream codedb's state

- **No data dir, no `data.log`.** The CLI no longer creates
  `~/.codedb/projects/<hash>/` (or `<root>/.codedb/` without a home dir) and no
  longer truncates the `data.log` there on every run. That path belongs to
  upstream `justrach/codedb`, so each codedb-core call emptied upstream's edit
  log for the project. Nothing read the file in this one-shot fork, so it is
  gone rather than moved.
- **Config is now `.codedb-corerc`** (in `$CWD`, then next to the binary).
  Upstream's `.codedbrc` is no longer read. Migration: `cp .codedbrc
  .codedb-corerc`, or pass `--config-file .codedbrc`. Keys are unchanged
  (`max_versions`, `max_cached`).
- **Reserved data dir**: `~/.codedb-core/projects/<wyhash(root)>` (or
  `<root>/.codedb-core`), defined in `src/state_paths.zig`. Nothing creates it
  today; the scanner skips `.codedb-core/` like `.codedb/`.
- **Tests**: `zig build test` now runs the config/state-path unit tests and an
  end-to-end check that builds the CLI and runs `tree`, `outline`, `search`,
  `symbol`, `callers`, `callees`, `neighbors`, and `status` with a seeded
  upstream `data.log` and `.codedbrc`, asserting both stay byte-identical and
  unread.

## 1.1.0

- **Minor Version Promotion**: Formal release of core intelligence hardening, resident execution mode, and adjacency query acceleration.
- **Single-pass `neighbors` command**: Combined bidirectional call-graph traversal (`callers` + `callees`) and ambiguity resolution in a single AST indexing pass, cutting query time in half for full adjacency queries.
- **Template-literal-aware callee extraction (`extractCallees`)**: Introduced a dedicated state machine handling nested backtick template literals (`` `...${...}...` ``) to prevent false-positive callee attributions from strings.
- **Dropped ambiguous edge metrics**: Added explicit tracking for `node_dropped_ambiguous_callers` and `node_dropped_ambiguous_callees` when non-ubiquitous identifier collisions occur, accompanied by clean Zig allocator memory reclamation in `CallGraph.deinit()`.
- **Zero-daemon resident server (`serve --stdio`)**: Windows Job Object death-supervised JSON-RPC stdio worker, amortizing the index scan across subsequent resident requests (sub-millisecond queries on warm graphs).

## 1.0.2

- **Single-pass `neighbors` command**: Combined bidirectional call-graph traversal (`callers` + `callees`) and ambiguity resolution in a single AST indexing pass, cutting query time in half for full adjacency queries.
- **Template-literal-aware callee extraction (`extractCallees`)**: Introduced a dedicated state machine handling nested backtick template literals (`` `...${...}...` ``) to prevent false-positive callee attributions from strings.
- **Dropped ambiguous edge metrics**: Added explicit tracking for `node_dropped_ambiguous_callers` and `node_dropped_ambiguous_callees` when non-ubiquitous identifier collisions occur, accompanied by clean Zig allocator memory reclamation in `CallGraph.deinit()`.
- **Zero-daemon resident server (`serve --stdio`)**: Windows Job Object death-supervised JSON-RPC stdio worker, amortizing the index scan across subsequent resident requests (0.26ms–0.75ms per query).

## 1.0.1

- Expose `./package.json` in the package `exports` so consumers can
  `require.resolve("@paragon-ux/codedb-core/package.json")` (the pattern
  waymark-engine's bundled-binary resolver uses).

## 1.0.0

Initial fork of `justrach/codedb` frozen at `428d8df` (v0.2.5826), Zig 0.16.0.

### Removed (deterministic core only)

Embeddings (`semantic*`, `ann`), telemetry, self-update/uninstall (`update`,
`nuke`), HTTP server, MCP server, portable snapshots, git-head tracking, the CLI
daemon thin-client, linter/edit tools, markdown reader, WASM, and the `openpuffer`
ANN dependency.

### Resolved, fail-closed call graph

- Replaced the fan-out `buildEdges` with a two-tier resolved edge builder:
  1. **same-file helper** — a bare callee resolves to the one definition in the
     caller's own file even when the name is ambiguous repo-wide;
  2. **globally-unique name**.
  Every tier is fail-closed: ambiguity emits no edge, so `callers`/`callees`
  never merge a bare-name collision into unrelated code.
- **Language-family guard**: a callee name resolves only to a definition in the
  same language family (JS/TS grouped), preventing a TS callee from resolving to
  a same-named Rust/C/C++/etc. definition.
- Added `callers` / `callees` CLI commands (reverse/forward adjacency), and a
  `--json` flag on every query command. On ambiguity, `callers`/`callees` surface
  the file-scoped candidate definitions (`"ambiguous": true`) instead of going
  silent.

### Parser fix (`findBraceEnd`)

codedb's JS/TS `line_end` computation was a stateful brace scanner that
mis-delimited function bodies on three constructs, producing false callers (body
absorbing the rest of the file) and missed callees. Rewrote it to correctly
lex **template literals** (`` ` `` + `${}` interpolation, nested), **regex
literals** (division-vs-regex disambiguation), and **TypeScript return-type
annotations** (`: { a: b }`, `: Promise<{...}>`). Verified against grep ground
truth on `openai/codex` (8,492 files): no false edges; only test-file functions
remain excluded (deliberate `isLikelyTestPath`).

### One-shot CLI

Each invocation scans the project once, answers deterministically, and exits.
No daemon, no index persistence, no network.
