//! Release metadata, set by build.zig at build time.

/// package.json's "version", so `codedb --version` matches the npm release.
pub const semver: []const u8 = @import("release_options").semver;
