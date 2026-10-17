# Install / build

`@paragon-ux/codedb-core` ships prebuilt binaries; end users need nothing
beyond Node (for the `codedb` bin shim) or the binary itself.

## Consuming the prebuilt package

```sh
npm install @paragon-ux/codedb-core
npx codedb --version
```

Or resolve the binary path programmatically:

```js
import { codedbBinaryPath } from "@paragon-ux/codedb-core";
const bin = codedbBinaryPath(); // absolute path, or null if unsupported
```

## Building from source

The fork is pinned to **Zig 0.16.0** (stable). Install it any way you like
(`zvm use 0.16.0`, `zigup 0.16.0`, or a direct tarball from ziglang.org).

```sh
zig build -Doptimize=ReleaseFast      # build the current platform
zig build test                        # unit tests + end-to-end state-isolation check
node scripts/build-all.mjs            # build current platform into dist/
```

### Cross-compiling

| Package binary          | Build command                              | Host |
| ----------------------- | ------------------------------------------ | ---- |
| `codedb-win32-x64.exe`  | `zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows` | any  |
| `codedb-linux-x64`      | `zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux`   | any  |
| `codedb-linux-arm64`    | `zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux`  | any  |
| `codedb-darwin-x64`     | build on macOS (`-Dtarget=x86_64-macos`)   | macOS |
| `codedb-darwin-arm64`   | build on macOS (`-Dtarget=aarch64-macos`)  | macOS |

macOS targets must be built on macOS (the linker needs the Apple SDK).

`zig build test` also builds the CLI and runs it against a temp project with a
seeded `~/.codedb/projects/<hash>/data.log` and `.codedbrc`, failing if either
changes or is read (see `src/state_isolation_test.zig`).

## Configuration and state

The CLI reads an optional `.codedb-corerc` and never creates a data dir. See
[README → On-disk state](./README.md#on-disk-state), including the migration
note for `.codedbrc` users.

### Release process

Releases go out from CI via npm Trusted Publishing
([`.github/workflows/release.yml`](./.github/workflows/release.yml)):

1. Bump `version` in `package.json` and add the `CHANGELOG.md` entry; commit.
2. Push a matching tag: `git tag v<version> && git push origin v<version>`.
3. The workflow runs `zig build test`, builds all five binaries (linux and
   win32 on Ubuntu, darwin on macOS), checks the tag matches `package.json`,
   packs with the binaries marked executable, and runs
   `npm publish --access public --provenance --ignore-scripts`. It skips the
   publish if that version is already on npm, and attaches the tarball to a
   GitHub Release.

To rehearse without publishing, run it by hand (`dry_run` defaults to true):

```sh
gh workflow run release.yml --ref main -f dry_run=true
```

Avoid publishing from a local checkout: `prepack` rebuilds only the host's
binary, and a Windows host can't set the exec bit on the darwin/linux
binaries.
