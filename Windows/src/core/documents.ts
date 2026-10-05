import type { Paragraph, ReadingDocument } from "./types";

export function textParagraphs(input: string, markdown = false): Paragraph[] {
  const normalized = input.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n");
  return normalized
    .split(/\n\s*\n/)
    .filter((t) => t.trim())
    .map((raw, index) => {
      let text = raw.trim();
      let kind: Paragraph["kind"] = "paragraph";
      let level: number | undefined;
      if (markdown) {
        const heading = /^(#{1,6})\s+(.+)$/s.exec(text);
        if (heading) {
          kind = "heading";
          level = heading[1]!.length;
          text = heading[2]!;
        } else if (/^>\s/m.test(text)) {
          kind = "quote";
          text = text.replace(/^>\s?/gm, "");
        } else if (/^([-*+] |\d+\. )/.test(text)) {
          kind = "list";
        } else if (/^```/.test(text)) {
          kind = "code";
          text = text.replace(/^```[^\n]*\n?/, "").replace(/\n?```$/, "");
        }
      }
      return { id: `p-${index}`, text, kind, ...(level ? { level } : {}) };
    });
}
export async function makeDocument(
  title: string,
  text: string,
  markdown = false,
): Promise<ReadingDocument> {
  if (!text.trim()) throw new Error("DOCUMENT_EMPTY");
  if (text.length > 5000000) throw new Error("DOCUMENT_TOO_LARGE");
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(text),
  );
  return {
    id: crypto.randomUUID(),
    title: title.trim().slice(0, 512) || "Untitled",
    sourceKind: "text",
    language: /[\u3400-\u9fff]/u.test(text) ? "zh" : "en",
    paragraphs: textParagraphs(text, markdown),
    importedAt: new Date().toISOString(),
    fingerprint: Array.from(new Uint8Array(digest), (n) =>
      n.toString(16).padStart(2, "0"),
    ).join(""),
  };
}
