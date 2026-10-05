import type { Entitlement, SpeechResult } from "./api";
import type {
  Account,
  ReaderPreferences,
  ReadingCheckpoint,
  ReadingDocument,
  Region,
} from "./types";
export interface Bootstrap {
  account: Account | null;
  preferences: ReaderPreferences;
  documents: ReadingDocument[];
  checkpoints: Record<string, ReadingCheckpoint>;
  platform: string;
  version: string;
}
export interface ImportedFile {
  name: string;
  extension: string;
  bytes: Uint8Array;
}
export interface DesktopBridge {
  bootstrap(): Promise<Bootstrap>;
  sendCode(email: string, region: Region): Promise<void>;
  signIn(email: string, otp: string, region: Region): Promise<Account>;
  signOut(): Promise<void>;
  entitlement(): Promise<Entitlement>;
  importFile(): Promise<ImportedFile | null>;
  saveDocument(document: ReadingDocument): Promise<void>;
  deleteDocument(id: string): Promise<void>;
  savePreferences(value: ReaderPreferences): Promise<void>;
  saveCheckpoint(value: ReadingCheckpoint): Promise<void>;
  speak(input: {
    text: string;
    voice: string;
    language: string;
    requestId: string;
  }): Promise<SpeechResult>;
  cancelSpeech(): Promise<void>;
  track(input: { eventId: string; seconds: number }): Promise<void>;
}
declare global {
  interface Window {
    castreader?: DesktopBridge;
  }
}
