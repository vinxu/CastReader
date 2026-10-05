import { createHash, randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
  unlinkSync,
} from "node:fs";
import { join } from "node:path";
import { safeStorage } from "electron";
import type { Session, Vault } from "../core/api";
import { defaultPreferences } from "../core/types";
import type {
  ReaderPreferences,
  ReadingDocument,
  ReadingCheckpoint,
} from "../core/types";
import { preferences, readingDocument } from "../core/validation";
import { validateCheckpoint } from "../core/resume";

interface Library {
  documents: ReadingDocument[];
  checkpoints: Record<string, ReadingCheckpoint>;
}
export class Storage implements Vault {
  constructor(private root: string) {
    mkdirSync(root, { recursive: true, mode: 0o700 });
  }
  private path(name: string) {
    return join(this.root, name);
  }
  private readJSON(name: string): unknown {
    try {
      return JSON.parse(readFileSync(this.path(name), "utf8"));
    } catch {
      return null;
    }
  }
  private writeJSON(name: string, value: unknown) {
    const temporary = this.path(`${name}.${randomUUID()}.tmp`);
    writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 });
    renameSync(temporary, this.path(name));
  }
  deviceId(): string {
    const stored = this.readJSON("device.json");
    if (typeof stored === "string" && /^[a-f0-9-]{36}$/.test(stored))
      return stored;
    const value = randomUUID();
    this.writeJSON("device.json", value);
    return value;
  }
  read(): Session | null {
    const path = this.path("session.bin");
    if (!existsSync(path)) return null;
    if (!safeStorage.isEncryptionAvailable())
      throw new Error("SECURE_STORAGE_UNAVAILABLE");
    try {
      const value = JSON.parse(
        safeStorage.decryptString(readFileSync(path)),
      ) as Session;
      if (
        !value.account?.id ||
        !["global", "cn"].includes(value.account.region) ||
        !value.token?.startsWith("cms_") ||
        value.token.startsWith("cms_local_") ||
        !value.identityToken
      )
        return null;
      return value;
    } catch {
      throw new Error("SECURE_STORAGE_UNAVAILABLE");
    }
  }
  write(value: Session | null) {
    const path = this.path("session.bin");
    if (!value) {
      if (existsSync(path)) unlinkSync(path);
      return;
    }
    if (!safeStorage.isEncryptionAvailable())
      throw new Error("SECURE_STORAGE_UNAVAILABLE");
    const tmp = path + ".tmp";
    writeFileSync(tmp, safeStorage.encryptString(JSON.stringify(value)), {
      mode: 0o600,
    });
    renameSync(tmp, path);
  }
  getPreferences(): ReaderPreferences {
    try {
      return preferences(this.readJSON("preferences.json"));
    } catch {
      return { ...defaultPreferences };
    }
  }
  savePreferences(value: unknown) {
    this.writeJSON("preferences.json", preferences(value));
  }
  private libraryFile(scope: string) {
    return `library-${createHash("sha256").update(scope).digest("hex")}.json`;
  }
  library(scope: string): Library {
    const raw = this.readJSON(this.libraryFile(scope)) as Library | null;
    if (!raw || !Array.isArray(raw.documents))
      return { documents: [], checkpoints: {} };
    const documents = raw.documents.flatMap((doc) => {
      try {
        return [readingDocument(doc)];
      } catch {
        return [];
      }
    });
    const checkpoints: Record<string, ReadingCheckpoint> = {};
    for (const doc of documents) {
      const c = validateCheckpoint(raw.checkpoints?.[doc.id], scope, doc);
      if (c) checkpoints[doc.id] = c;
    }
    return { documents, checkpoints };
  }
  saveDocument(scope: string, value: unknown) {
    const doc = readingDocument(value),
      library = this.library(scope);
    library.documents = [
      doc,
      ...library.documents.filter((d) => d.id !== doc.id),
    ];
    if (library.documents.length > 1000) throw new Error("LIBRARY_LIMIT");
    this.writeJSON(this.libraryFile(scope), library);
  }
  deleteDocument(scope: string, id: string) {
    const library = this.library(scope);
    library.documents = library.documents.filter((d) => d.id !== id);
    delete library.checkpoints[id];
    this.writeJSON(this.libraryFile(scope), library);
  }
  saveCheckpoint(scope: string, value: ReadingCheckpoint) {
    const library = this.library(scope),
      doc = library.documents.find((d) => d.id === value.documentId);
    const checked = doc ? validateCheckpoint(value, scope, doc) : null;
    if (!checked) throw new Error("INVALID_CHECKPOINT");
    library.checkpoints[checked.documentId] = checked;
    this.writeJSON(this.libraryFile(scope), library);
  }
}
