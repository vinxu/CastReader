import { expect, it } from "vitest";
import { zipSync, strToU8 } from "fflate";
import { archivePath, safeArchive } from "../src/core/archive";
it("does not accept archive traversal or absolute resource URLs", () => {
  expect(() =>
    safeArchive(zipSync({ "../outside.txt": strToU8("test") })),
  ).toThrow("INVALID_ARCHIVE_PATH");
  expect(() => archivePath("OPS/book.opf", "../../outside")).toThrow(
    "INVALID_ARCHIVE_PATH",
  );
  expect(() =>
    archivePath("OPS/book.opf", "https://example.com/private"),
  ).toThrow("INVALID_ARCHIVE_PATH");
  expect(archivePath("OPS/chapter/one.xhtml", "../images/cover.png")).toBe(
    "OPS/images/cover.png",
  );
});
