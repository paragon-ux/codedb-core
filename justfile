set shell := ["powershell", "-NoLogo", "-Command"]

build:
    zig build -Doptimize=ReleaseFast

build-debug:
    zig build

test:
    zig build test

# Build the current platform's binary into dist/ (what `npm pack` needs).
dist:
    node scripts/build-all.mjs

# Cross-compile the Linux binaries (works from any host).
dist-linux:
    node scripts/build-all.mjs linux-x64
    node scripts/build-all.mjs linux-arm64

install:
    zig build -Doptimize=ReleaseFast
    node scripts/build-all.mjs

fmt:
    zig fmt src build.zig
