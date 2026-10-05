import type { ReadingCheckpoint, ReadingDocument } from "./types";
export function validateCheckpoint(
  value: unknown,
  accountScope: string,
  doc: ReadingDocument,
): ReadingCheckpoint | null {
  if (!value || typeof value !== "object") return null;
  const c = value as ReadingCheckpoint;
  if (
    c.version !== 1 ||
    c.accountScope !== accountScope ||
    c.documentId !== doc.id ||
    c.fingerprint !== doc.fingerprint
  )
    return null;
  const p = doc.paragraphs.find((p) => p.id === c.paragraphId);
  if (
    !p ||
    !Number.isInteger(c.sourceOffset) ||
    c.sourceOffset < 0 ||
    c.sourceOffset > p.text.length
  )
    return null;
  if (
    c.sourceOffset > 0 &&
    /[\uDC00-\uDFFF]/.test(p.text[c.sourceOffset] ?? "") &&
    /[\uD800-\uDBFF]/.test(p.text[c.sourceOffset - 1] ?? "")
  )
    return null;
  if (
    !Number.isFinite(c.segmentSeconds) ||
    c.segmentSeconds < 0 ||
    !["read", "explain"].includes(c.mode)
  )
    return null;
  return c;
}
