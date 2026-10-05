export type SourceKind =
  | "text"
  | "epub"
  | "docx"
  | "pdf"
  | "photo"
  | "web"
  | "kindle"
  | "weread"
  | "kobo"
  | "google_books"
  | "oreilly"
  | "youtube";
export type Region = "global" | "cn";
export type ParagraphKind =
  "paragraph" | "heading" | "list" | "quote" | "code" | "image";
export interface Paragraph {
  id: string;
  text: string;
  kind: ParagraphKind;
  level?: number;
  image?: string;
  page?: number;
}
export interface ReadingDocument {
  id: string;
  title: string;
  sourceKind: SourceKind;
  language: string;
  paragraphs: Paragraph[];
  importedAt: string;
  fingerprint: string;
}
export interface Timestamp {
  word: string;
  start: number;
  end: number;
}
export interface SourceRange {
  start: number;
  end: number;
}
export interface AudioSegment {
  id: string;
  paragraphId: string;
  text: string;
  sourceOffset: number;
  sourceLength?: number;
  audio: string;
  audioFormat: string;
  timestamps: Timestamp[];
  duration: number;
}
export interface ReadingCheckpoint {
  version: 1;
  accountScope: string;
  documentId: string;
  fingerprint: string;
  paragraphId: string;
  sourceOffset: number;
  segmentSeconds: number;
  updatedAt: string;
  mode: "read" | "explain";
}
export interface ReaderPreferences {
  theme: "system" | "light" | "dark";
  fontSize: number;
  speed: number;
  voice: string;
  language: string;
  locale: string;
}
export interface Account {
  id: string;
  email: string;
  displayName: string;
  region: Region;
}
export const defaultPreferences: ReaderPreferences = {
  theme: "system",
  fontSize: 21,
  speed: 1,
  voice: "af_heart",
  language: "en",
  locale: "en",
};
export const locales = [
  "en",
  "zh-Hans",
  "ja",
  "es",
  "fr",
  "de",
  "pt-BR",
  "it",
  "hi",
] as const;
