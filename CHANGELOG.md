# @paragon-ux/codedb-core

## [Unreleased]

- **A name prefers its one definition outside test files.** Since 2.1.0, object-literal functions are call-graph nodes, so test mocks such as `queryCapnMemory: async () => {…}` passed to the code under test share the real function's name. `callers`, `callees`, and `neighbors` then reported `queryCapnMemory` as ambiguous, with the real function and nine mocks as candidates.
  - A bare or qualified name that matches several definitions now resolves to the one outside test files. A file counts as a test file under the same rule edge resolution uses. Edge resolution already never resolves a call to a test-file definition.
  - Several non-test definitions are still ambiguous, and the response still lists every candidate, test ones included. A name whose definitions are all in test files is ambiguous as before. Ambiguous names still emit no edge.
  - A name that resolves to one node is never reported as ambiguous, even when it has no callers or callees.
  - `symbol` is unchanged: it lists definitions and doesn't resolve a name.
  - In the library, `CallGraph.lookup` does the resolution, and `StepsWithStats.resolved` reports whether `callersOfWithStats`/`calleesOfWithStats` resolved the name.
- **Tests**: `src/ts_callgraph_test.zig` covers a src function with same-named test mocks, two src definitions with a mock, and mocks only. `src/neighbors_json_test.zig` checks the CLI JSON for a resolved name with and without neighbors.

## 2.1.0

- **TypeScript and JavaScript callers inside class methods, object-literal functions, and arrow consts.** Only `.function` and `.method` symbols are call-graph nodes. The TS/JS outline produced no symbol for class methods (`async start() {`) or function-valued object properties (`handler: async (args) => {`), and recorded arrow-function consts as `.constant`, so `callers`, `callees`, and `neighbors` had no caller for the calls inside them. These are now nodes:
  - `.method`: class members (including constructors, `get`/`set`, `static`, `async`, `*` generators, `#private` names, access modifiers, arrow-valued fields such as `onExit = () => this.stop();`, and multi-line parameter lists), plus function-valued object properties and shorthand methods (`plain(args) {`).
  - `.function`: `const`/`let`/`var` whose value is an arrow function.
  - Not nodes: overload and abstract signatures ending in `;`, interface and type-literal members, and control-flow or call lines.
  - Callables nested inside another function's body aren't added, because their calls already belong to that function.
  - An expression-bodied arrow ends where its expression ends instead of taking the next brace block in the file.
- **TS/JS calls without a receiver never resolve to a method.** A method is reachable only through `obj.name(`, `this.name(`, or `super.name(`. A bare `start()` now resolves among free functions and arrow consts only, so a parameter named `start` no longer gets an edge to `WaymarkDaemon.start`. Also, a bare `stop()` beside a same-named method now reaches the free function instead of being ambiguous. Calls with a receiver keep every candidate, ambiguous names still emit no edge, and other languages resolve as before. `extractCalleeRefs` reports each callee's bare and receiver calls; `extractCallees` is unchanged.
- **Every call-graph node in `--json` output has `kind` and `qualified`.** `callers`, `callees`, and `neighbors` results now look like `{"path","name","line","kind","qualified"}`:
  - `kind` is `"function"`, `"method"`, or `"module"`.
  - `qualified` is the owner-qualified name of a TS/JS member, and equals `name` otherwise. A class member is `Class.member`. An object-literal member is `binding.member`, where the binding is the `const`/`let`/`var` the object is assigned to, or `default` for `export default {`. Nested objects and class-field objects join with dots (`tools.nested.inner`, `Svc.handlers.onData`).
  - An object without a binding, such as one passed as an argument, keeps bare names.
  - `name` is unchanged and stays the bare name. In the library, `Symbol.qualified` holds the qualified name, and `CallPathStep` gains `kind` plus `qualified`, which callers of `callersOf`/`calleesOf`/`bothNeighborsOf` free along with `path` and `name`.
  - The candidates of an ambiguity response and `symbol --json` results carry `qualified` too. `searchSymbols` results now own a copy of `symbol.qualified`; free a result with `Explorer.freeScoredSymbol`.
- **`callers`, `callees`, and `neighbors` accept a qualified name.** A dotted name such as `WaymarkDaemon.start` matches a node's qualified name exactly. A bare name resolves as before, including the ambiguity response, so `start` is still ambiguous when two classes define it. Edge resolution is unchanged: calls are matched by their bare callee name.
  - A qualified name that matches more than one definition, such as a getter and setter both named `Shapes.size`, gets the same ambiguity response as a bare name: `"ambiguous": true` with every candidate's path, line, kind and qualified name. It still emits no edge.
  - A qualified name that matches nothing reports `"symbol_exists": false`, so a caller can retry with the bare name.
  - `Explorer.neighborCandidates` returns the definitions a bare or qualified name refers to.
- **TS/JS module nodes for top-level code.** Each TS/JS file gets a node named `<module>` (kind `module`, line 1). Its body is the file with every function and method span blanked, so it owns calls in top-level statements and in anonymous top-level callbacks (`test("…", async () => {…})`, `process.once("exit", () => …)`) without duplicating calls that a named node owns.
  - Module nodes only call: nothing resolves to them.
  - They use the same resolution tiers as other nodes, including the bare-call rule.
  - They're left out of the call-graph centrality and graph-distance boosts, so search ranking doesn't change.
- **A declaration's own name no longer counts as a call** (all languages). Call-graph bodies start at the declaration line, so the `foo` in `fn foo(`, `def foo(`, or `async foo(` counted as a call to `foo`. When exactly one other definition of that name existed, this made a false edge, such as two unrelated `canonicalRoot` functions each calling the other. Nested `function helper(` and `fn lt(` declarations no longer count as calls either.
- **TS/JS spans past multi-line template literals.** Skipping a template literal didn't count its newlines, so a function containing one ended early and lost the calls after it.
- **Destructured parameters in typed TS arrows.** In `handler: ({ a }) => {` and `cb: T = ({ a }) => {`, the parameter's brace was taken as the body.
- Lines like `parse(type: string) {` are no longer recorded as a `type_alias` named after the method.
- **Tests**: `zig build test` now also runs:
  - `src/ts_callgraph_test.zig`: each shape above, the call graph across two files, bare and receiver calls, qualified names and lookup, module nodes, and negative cases.
  - `src/neighbors_json_test.zig`: runs the built CLI and checks the `kind`/`qualified` JSON, qualified queries, and the ambiguity response for a qualified name.
  - The `codegraph.zig` unit tests, which were never part of the test build before.

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
