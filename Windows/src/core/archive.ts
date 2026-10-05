import { unzipSync } from "fflate";
export function safeArchive(bytes: Uint8Array): Record<string, Uint8Array> {
  if (bytes.byteLength > 50000000) throw new Error("FILE_TOO_LARGE");
  let total = 0,
    count = 0;
  const names = new Set<string>();
  const files = unzipSync(bytes, {
    filter: (entry) => {
      if (
        ++count > 10000 ||
        entry.originalSize > 32000000 ||
        (total += entry.originalSize) > 128000000
      )
        throw new Error("ARCHIVE_TOO_LARGE");
      if (
        entry.name.includes("\\") ||
        entry.name.startsWith("/") ||
        entry.name.split("/").includes("..") ||
        names.has(entry.name)
      )
        throw new Error("INVALID_ARCHIVE_PATH");
      names.add(entry.name);
      return !entry.name.endsWith("/");
    },
  });
  if (Object.values(files).reduce((n, b) => n + b.byteLength, 0) > 128000000)
    throw new Error("ARCHIVE_TOO_LARGE");
  return files;
}
export function archivePath(base: string, relative: string): string {
  const path = decodeURIComponent(relative.split("#")[0]!).replace(/\\/g, "/");
  if (/^([a-z]+:|\/)/i.test(path)) throw new Error("INVALID_ARCHIVE_PATH");
  const parts = base.split("/").slice(0, -1);
  for (const p of path.split("/")) {
    if (p === "..") {
      if (!parts.length) throw new Error("INVALID_ARCHIVE_PATH");
      parts.pop();
    } else if (p && p !== ".") parts.push(p);
  }
  return parts.join("/");
}
