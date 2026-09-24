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
zig build test                        # compile-check the module surface
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

### Release process

1. On each platform, run `node scripts/build-all.mjs` to drop the matching
   binary into `dist/`.
2. Collect all five `dist/` binaries into one tree.
3. `npm run changeset` (or a manual changeset), then `npm publish`.

The `prepack` hook rebuilds the current platform's binary before packing, so a
local `npm pack` always ships a self-consistent binary for the host.
