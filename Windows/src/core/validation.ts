import type { ReaderPreferences, ReadingDocument, Region } from "./types";
import { locales } from "./types";

export function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("INVALID_RESPONSE");
  return value as Record<string, unknown>;
}
export function string(value: unknown, max = 4096): string {
  if (typeof value !== "string" || value.length > max)
    throw new Error("INVALID_INPUT");
  return value;
}
export function region(value: unknown): Region {
  if (value !== "global" && value !== "cn") throw new Error("INVALID_REGION");
  return value;
}
export function email(value: unknown) {
  const normalized = string(value, 254).trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized))
    throw new Error("INVALID_EMAIL");
  return normalized;
}
export function preferences(value: unknown): ReaderPreferences {
  const p = record(value);
  if (
    !["system", "light", "dark"].includes(String(p.theme)) ||
    !locales.includes(p.locale as (typeof locales)[number]) ||
    typeof p.fontSize !== "number" ||
    p.fontSize < 14 ||
    p.fontSize > 40 ||
    typeof p.speed !== "number" ||
    p.speed < 0.5 ||
    p.speed > 4 ||
    typeof p.language !== "string" ||
    !/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/.test(p.language) ||
    typeof p.voice !== "string" ||
    !/^[a-zA-Z0-9_-]{1,100}$/.test(p.voice)
  )
    throw new Error("INVALID_PREFERENCES");
  return p as unknown as ReaderPreferences;
}
export function readingDocument(value: unknown): ReadingDocument {
  const d = record(value);
  for (const k of ["id", "title", "language", "importedAt", "fingerprint"])
    string(d[k], k === "title" ? 512 : 128);
  if (
    !/^[a-zA-Z0-9-]{1,80}$/.test(d.id as string) ||
    ![
      "text",
      "epub",
      "docx",
      "pdf",
      "photo",
      "web",
      "kindle",
      "weread",
      "kobo",
      "google_books",
      "oreilly",
      "youtube",
    ].includes(String(d.sourceKind))
  )
    throw new Error("INVALID_DOCUMENT");
  if (
    !Array.isArray(d.paragraphs) ||
    !d.paragraphs.length ||
    d.paragraphs.length > 100000
  )
    throw new Error("INVALID_DOCUMENT");
  const ids = new Set<string>();
  let length = 0;
  for (const raw of d.paragraphs) {
    const p = record(raw),
      id = string(p.id, 100),
      text = string(p.text, 1000000);
    if (
      ids.has(id) ||
      !["paragraph", "heading", "list", "quote", "code", "image"].includes(
        String(p.kind),
      )
    )
      throw new Error("INVALID_DOCUMENT");
    if (
      p.image !== undefined &&
      !/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$/.test(
        string(p.image, 15000000),
      )
    )
      throw new Error("INVALID_IMAGE");
    length += text.length + (typeof p.image === "string" ? p.image.length : 0);
    ids.add(id);
  }
  if (length > 40000000) throw new Error("DOCUMENT_TOO_LARGE");
  return d as unknown as ReadingDocument;
}
