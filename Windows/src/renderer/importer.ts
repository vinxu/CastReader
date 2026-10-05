import type { ImportedFile } from "../core/bridge";
import { makeDocument, textParagraphs } from "../core/documents";
import type { Paragraph, ReadingDocument } from "../core/types";
import { archivePath, safeArchive } from "../core/archive";

const decoder = new TextDecoder("utf-8", { fatal: true });
function xml(value: Uint8Array | undefined): Document {
  if (!value) throw new Error("EPUB_MISSING_RESOURCE");
  const doc = new DOMParser().parseFromString(
    decoder.decode(value),
    "application/xml",
  );
  if (doc.querySelector("parsererror")) throw new Error("EPUB_INVALID_XML");
  return doc;
}
function elements(doc: Document | Element, name: string) {
  return Array.from(doc.getElementsByTagNameNS("*", name));
}
function epubParagraphs(bytes: Uint8Array): {
  title?: string;
  paragraphs: Paragraph[];
} {
  const files = safeArchive(bytes),
    container = xml(files["META-INF/container.xml"]);
  const opfPath = elements(container, "rootfile")[0]?.getAttribute("full-path");
  if (!opfPath || opfPath.startsWith("/") || opfPath.split("/").includes(".."))
    throw new Error("EPUB_INVALID_CONTAINER");
  const opf = xml(files[opfPath]),
    manifest = new Map(
      elements(opf, "item").map((el) => [el.getAttribute("id"), el]),
    );
  const paragraphs: Paragraph[] = [];
  for (const entry of elements(opf, "itemref")) {
    const item = manifest.get(entry.getAttribute("idref")),
      href = item?.getAttribute("href");
    if (!href) throw new Error("EPUB_INVALID_SPINE");
    const path = archivePath(opfPath, href),
      chapter = xml(files[path]),
      body = elements(chapter, "body")[0];
    if (!body) continue;
    const walk = (el: Element) => {
      const tag = el.localName.toLowerCase();
      if (
        [
          "script",
          "style",
          "nav",
          "noscript",
          "iframe",
          "object",
          "svg",
        ].includes(tag)
      )
        return;
      if (tag === "img") {
        const src = el.getAttribute("src");
        if (!src) return;
        let imagePath: string;
        try {
          imagePath = archivePath(path, src);
        } catch {
          return;
        }
        const image = files[imagePath],
          ext = imagePath.split(".").at(-1)?.toLowerCase();
        const mime =
          ext === "png"
            ? "png"
            : ext === "webp"
              ? "webp"
              : ["jpg", "jpeg"].includes(ext ?? "")
                ? "jpeg"
                : null;
        if (!image || !mime || image.length > 8000000) return;
        let binary = "";
        for (let i = 0; i < image.length; i += 8192)
          binary += String.fromCharCode(...image.subarray(i, i + 8192));
        paragraphs.push({
          id: `p-${paragraphs.length}`,
          text: "",
          kind: "image",
          image: `data:image/${mime};base64,${btoa(binary)}`,
        });
        return;
      }
      const isBlock = /^(p|h[1-6]|blockquote|li|pre|td)$/.test(tag);
      if (
        isBlock &&
        !el.querySelector("p,h1,h2,h3,h4,h5,h6,blockquote,li,pre,td,img")
      ) {
        const text = el.textContent?.replace(/\s+/g, " ").trim();
        if (text)
          paragraphs.push({
            id: `p-${paragraphs.length}`,
            text,
            kind: /^h\d$/.test(tag)
              ? "heading"
              : tag === "blockquote"
                ? "quote"
                : tag === "pre"
                  ? "code"
                  : tag === "li"
                    ? "list"
                    : "paragraph",
            ...(/^h\d$/.test(tag) ? { level: Number(tag[1]) } : {}),
          });
      } else {
        for (const node of Array.from(el.childNodes)) {
          if (node.nodeType === Node.ELEMENT_NODE) walk(node as Element);
          else if (node.nodeType === Node.TEXT_NODE && node.textContent?.trim())
            paragraphs.push({
              id: `p-${paragraphs.length}`,
              text: node.textContent.trim(),
              kind: "paragraph",
            });
        }
      }
    };
    walk(body);
  }
  return { title: elements(opf, "title")[0]?.textContent?.trim(), paragraphs };
}
export async function importDocument(
  file: ImportedFile,
): Promise<ReadingDocument> {
  if (file.bytes.length > 50000000) throw new Error("FILE_TOO_LARGE");
  if (["txt", "md", "markdown"].includes(file.extension))
    return makeDocument(
      file.name,
      decoder.decode(file.bytes),
      file.extension !== "txt",
    );
  let paragraphs: Paragraph[],
    title = file.name;
  if (file.extension === "epub") {
    const result = epubParagraphs(file.bytes);
    paragraphs = result.paragraphs;
    title = result.title || title;
  } else if (file.extension === "docx") {
    safeArchive(file.bytes);
    const mammoth = await import("mammoth/mammoth.browser");
    const { value } = await mammoth.extractRawText({
      arrayBuffer: Uint8Array.from(file.bytes).buffer,
    });
    paragraphs = textParagraphs(value);
  } else if (file.extension === "pdf") {
    const pdfjs = await import("pdfjs-dist");
    const worker = await import("pdfjs-dist/build/pdf.worker.min.mjs?url");
    pdfjs.GlobalWorkerOptions.workerSrc = worker.default;
    const task = pdfjs.getDocument({
      data: Uint8Array.from(file.bytes),
      useSystemFonts: true,
    });
    const pdf = await task.promise;
    paragraphs = [];
    try {
      if (pdf.numPages > 2000) throw new Error("DOCUMENT_TOO_LARGE");
      for (let n = 1; n <= pdf.numPages; n++) {
        const page = await pdf.getPage(n),
          content = await page.getTextContent();
        const text = content.items
          .map((item) =>
            "str" in item ? item.str + (item.hasEOL ? "\n" : " ") : "",
          )
          .join("");
        for (const p of textParagraphs(text))
          paragraphs.push({ ...p, id: `p-${paragraphs.length}`, page: n });
        page.cleanup();
      }
    } finally {
      await task.destroy();
    }
  } else throw new Error("UNSUPPORTED_FILE");
  if (!paragraphs.some((p) => p.text.trim()))
    throw new Error(
      file.extension === "pdf" ? "PDF_NEEDS_OCR" : "DOCUMENT_EMPTY",
    );
  const digest = await crypto.subtle.digest(
    "SHA-256",
    Uint8Array.from(file.bytes),
  );
  return {
    id: crypto.randomUUID(),
    title,
    sourceKind: file.extension as ReadingDocument["sourceKind"],
    language: /[\u3400-\u9fff]/.test(
      paragraphs
        .slice(0, 10)
        .map((p) => p.text)
        .join(""),
    )
      ? "zh"
      : "en",
    paragraphs,
    importedAt: new Date().toISOString(),
    fingerprint: Array.from(new Uint8Array(digest), (n) =>
      n.toString(16).padStart(2, "0"),
    ).join(""),
  };
}
