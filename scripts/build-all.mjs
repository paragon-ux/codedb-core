import { spawnSync } from "node:child_process";
import { mkdirSync, copyFileSync, existsSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

const TARGETS = {
  "win32-x64": { zig: "x86_64-windows", exe: true },
  "darwin-arm64": { zig: "aarch64-macos", exe: false },
  "darwin-x64": { zig: "x86_64-macos", exe: false },
  "linux-x64": { zig: "x86_64-linux", exe: false },
  "linux-arm64": { zig: "aarch64-linux", exe: false },
};

const current = `${process.platform}-${process.arch}`;
const requested = process.argv[2] ?? current;

if (!(requested in TARGETS)) {
  console.error(`unsupported target: ${requested}`);
  process.exit(1);
}

const { zig, exe } = TARGETS[requested];
const outName = `codedb-${requested}${exe ? ".exe" : ""}`;
const zigOut = join(root, "zig-out", "bin", exe ? "codedb.exe" : "codedb");
const dist = join(root, "dist");

const cross = requested !== current;

// macOS targets must be built on macOS (linker requires the SDK); linux/win
// cross-compile fine via -Dtarget.
if (cross && zig.startsWith("x86_64-macos") && process.platform !== "darwin") {
  console.error(`${requested} must be built on macOS (SDK required). Skipping.`);
  process.exit(0);
}

const args = ["build", "-Doptimize=ReleaseFast"];
if (cross) args.push(`-Dtarget=${zig}`);

console.log(`zig ${args.join(" ")}`);
const build = spawnSync("zig", args, { cwd: root, stdio: "inherit" });
if (build.status !== 0) process.exit(build.status ?? 1);

if (!existsSync(zigOut)) {
  console.error(`build produced no binary at ${zigOut}`);
  process.exit(1);
}

mkdirSync(dist, { recursive: true });
const dest = join(dist, outName);
rmSync(dest, { force: true });
copyFileSync(zigOut, dest);
console.log(`wrote ${dest}`);
