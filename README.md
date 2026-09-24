# @paragon-ux/codedb-core

Deterministic structural code intelligence. A lexical-only fork of
[`justrach/codedb`](https://github.com/justrach/codedb) that keeps the
fast, self-contained symbol index + call graph and strips everything
statistical, networked, or daemon-shaped.

**No embeddings. No telemetry. No cloud. No MCP server. No daemon.** One
binary, one scan, one deterministic answer.

## Why this fork

`codedb` is an excellent engine, but its surface grew to include an ANN
embedding layer, a hosted semantic composer, telemetry, cloud auth, a
Web/DeepWiki remote, and long-lived MCP/HTTP daemons. This fork removes all
of that and keeps only the parts that answer a query *deterministically*:

- `outline` — every symbol in a file.
- `symbol` / `find` — where a symbol is defined (ranked, exact/prefix/glob).
- `callers` / `callees` — the **resolved, fail-closed** call graph.
- `callpath` — shortest resolved call chain between two functions.
- `deps` — import/dependency graph.
- `tree` / `glob` / `ls` / `file` — repo structure and path matching.
- `search` / `word` / `read` / `hot` / `status` — text and identifier lookup.

### The call graph is resolved and fail-closed

`callers` and `callees` resolve each call site to a definition **only when the
resolution is unambiguous** (same-file helper, or globally-unique name, within
the same language family). A bare-name collision never merges unrelated
definitions. Instead, on ambiguity the command surfaces the file-scoped
candidate definitions (`"ambiguous": true`) so the consumer can disambiguate —
the "never guess" contract, without going silent.

## Install

See [INSTALL.md](./INSTALL.md). Published as a single scoped package with
prebuilt binaries for `win32-x64`, `darwin-arm64`, `darwin-x64`, `linux-x64`,
and `linux-arm64`.

```sh
npm install @paragon-ux/codedb-core
```

## Usage

```sh
codedb [root] <command> [args...]
```

Every command accepts `--json` for machine-readable output:

```sh
codedb . symbol runQuery --json
codedb . callers runQuery --json
codedb . callees runQuery --json
codedb . outline src/query.zig --json
codedb . tree --json
```

```json
{"ok":true,"tool":"callers","count":1,"results":[{"path":"src/main.zig","name":"mainImpl","line":81}]}
```

Exit code `0` on success (including a valid query that finds nothing), `1` on
usage error or operational failure.

## Freeze

This fork is pinned to upstream commit `428d8df` (v0.2.5826), the last commit
that builds on the stable **Zig 0.16.0** toolchain and still contains the
resolved call graph. No upstream tracking.

## License

BSD-3-Clause, inherited from `justrach/codedb`.
