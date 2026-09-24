import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { existsSync } from "node:fs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const BINARIES = {
  "win32-x64": "codedb-win32-x64.exe",
  "darwin-arm64": "codedb-darwin-arm64",
  "darwin-x64": "codedb-darwin-x64",
  "linux-x64": "codedb-linux-x64",
  "linux-arm64": "codedb-linux-arm64",
};

/**
 * Resolve the absolute path of the prebuilt codedb-core binary for the current
 * platform, or null when no binary is bundled for it.
 */
export function codedbBinaryPath() {
  const key = `${process.platform}-${process.arch}`;
  const name = BINARIES[key];
  if (!name) return null;
  const candidate = join(__dirname, name);
  return existsSync(candidate) ? candidate : null;
}
