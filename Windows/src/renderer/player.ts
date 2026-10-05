import type { DesktopBridge } from "../core/bridge";
import { PlaybackQueue } from "../core/playback-queue";
import { alignWords, SpeechProjection } from "../core/speech-projection";
import { validateCheckpoint } from "../core/resume";
import type { AlignedWord } from "../core/speech-projection";
import type {
  ReadingDocument,
  ReaderPreferences,
  ReadingCheckpoint,
  SourceRange,
} from "../core/types";

export interface PlayerState {
  status: ReturnType<PlaybackQueue["snapshot"]>["status"];
  paragraphId: string | null;
  range: SourceRange | null;
  seconds: number;
  error: string | null;
}
export class ReaderPlayer {
  private queue = new PlaybackQueue();
  private listeners = new Set<() => void>();
  private audio = new Audio();
  private url: string | null = null;
  private installed: string | null = null;
  private words: AlignedWord[] = [];
  private doc: ReadingDocument | null = null;
  private accountScope = "";
  private prefs: ReaderPreferences | null = null;
  private checkpoint: ReadingCheckpoint | null = null;
  private lastSave = 0;
  private lastTick = 0;
  private usageSeconds = 0;
  private wakeProducer: (() => void) | null = null;
  private state: PlayerState = {
    status: "idle",
    paragraphId: null,
    range: null,
    seconds: 0,
    error: null,
  };
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };
  snapshot = () => this.state;
  constructor(private bridge: DesktopBridge) {
    this.audio.preload = "auto";
    this.audio.ontimeupdate = () => this.tick();
    this.audio.onended = () => {
      const s = this.queue.snapshot();
      if (!s.current) return;
      this.saveCheckpoint(
        s.current.sourceOffset +
          (s.current.sourceLength ?? s.current.text.length),
        0,
      );
      this.queue.ended(s.generation, s.current.id);
      this.wakeProducer?.();
      this.sync();
    };
    this.audio.onerror = () => {
      if (this.installed) {
        const s = this.queue.snapshot();
        this.queue.fail(s.generation, "AUDIO_PLAYBACK_FAILED");
        this.sync();
      }
    };
    this.audio.onwaiting = () => {
      this.lastTick = 0;
    };
    this.audio.onplaying = () => {
      this.lastTick = performance.now();
    };
  }
  async start(
    doc: ReadingDocument,
    prefs: ReaderPreferences,
    scope: string,
    checkpoint?: ReadingCheckpoint | null,
    paragraphId?: string,
  ) {
    this.stop();
    this.doc = doc;
    this.prefs = prefs;
    this.accountScope = scope;
    const resume = paragraphId
      ? null
      : validateCheckpoint(checkpoint, scope, doc);
    const generation = this.queue.begin();
    this.sync();
    await this.bridge.cancelSpeech();
    if (this.queue.snapshot().generation !== generation) return;
    let index = Math.max(
      0,
      doc.paragraphs.findIndex(
        (p) => p.id === (paragraphId ?? resume?.paragraphId),
      ),
    );
    try {
      for (; index < doc.paragraphs.length; index++) {
        const paragraph = doc.paragraphs[index]!;
        if (paragraph.kind === "image" || !paragraph.text.trim()) continue;
        let offset =
          paragraph.id === resume?.paragraphId ? resume.sourceOffset : 0;
        while (paragraph.text.slice(offset).trim()) {
          if (generation !== this.queue.snapshot().generation) return;
          while (this.queue.snapshot().queued >= 3) {
            await new Promise<void>((resolve) => {
              this.wakeProducer = resolve;
            });
            this.wakeProducer = null;
            if (generation !== this.queue.snapshot().generation) return;
          }
          const projection = new SpeechProjection(paragraph.text.slice(offset));
          const response = await this.bridge.speak({
            text: projection.wire,
            voice: prefs.voice,
            language: prefs.language,
            requestId: crypto.randomUUID(),
          });
          if (generation !== this.queue.snapshot().generation) return;
          const mapped = projection.resolve(
            response.processed,
            response.remaining,
          );
          this.queue.enqueue(generation, {
            id: crypto.randomUUID(),
            paragraphId: paragraph.id,
            sourceOffset: offset,
            sourceLength: mapped.consumed,
            text:
              response.processed ??
              projection.wire.slice(
                0,
                projection.wire.length - (response.remaining?.length ?? 0),
              ),
            audio: response.audio,
            audioFormat: response.audioFormat,
            duration: response.duration,
            timestamps: response.timestamps,
          });
          offset += mapped.consumed;
          this.sync();
        }
      }
      this.queue.finishGeneration(generation);
      this.sync();
    } catch (error) {
      if (generation === this.queue.snapshot().generation) {
        this.queue.fail(generation, readableError(error));
        this.sync();
      }
    }
  }
  pause() {
    this.tick();
    this.queue.pause();
    this.audio.pause();
    this.lastTick = 0;
    this.persist();
    this.flushUsage();
    this.sync();
  }
  resume() {
    this.queue.resume();
    this.sync();
  }
  stop() {
    this.tick();
    this.persist();
    this.flushUsage();
    this.queue.stop();
    this.audio.pause();
    this.lastTick = 0;
    this.installed = null;
    this.audio.removeAttribute("src");
    this.audio.load();
    if (this.url) URL.revokeObjectURL(this.url);
    this.url = null;
    this.wakeProducer?.();
    this.wakeProducer = null;
    this.words = [];
    this.checkpoint = null;
    void this.bridge.cancelSpeech();
    this.sync();
  }
  setSpeed(speed: number) {
    this.audio.playbackRate = speed;
    if (this.prefs) this.prefs = { ...this.prefs, speed };
  }
  dispose() {
    this.stop();
    this.audio.ontimeupdate = null;
    this.audio.onended = null;
    this.audio.onerror = null;
    this.audio.onplaying = null;
    this.audio.onwaiting = null;
    this.listeners.clear();
  }
  private sync() {
    const s = this.queue.snapshot(),
      segment = s.current;
    if (segment && this.installed !== segment.id) {
      this.audio.pause();
      if (this.url) URL.revokeObjectURL(this.url);
      const bytes = Uint8Array.from(atob(segment.audio), (c) =>
        c.charCodeAt(0),
      );
      this.url = URL.createObjectURL(
        new Blob([bytes], {
          type: segment.audioFormat === "wav" ? "audio/wav" : "audio/mpeg",
        }),
      );
      this.audio.src = this.url;
      this.audio.playbackRate = this.prefs?.speed ?? 1;
      this.installed = segment.id;
      const source =
        this.doc?.paragraphs.find((p) => p.id === segment.paragraphId)?.text ??
        "";
      this.words = alignWords(
        source,
        segment.text,
        segment.timestamps,
        segment.sourceOffset,
      );
      this.saveCheckpoint(segment.sourceOffset, 0);
    }
    if (s.status === "playing" && this.audio.paused) {
      const generation = s.generation,
        id = segment?.id;
      void this.audio.play().catch((error) => {
        if (
          this.queue.snapshot().generation !== generation ||
          this.installed !== id
        )
          return;
        if (error.name === "AbortError") return;
        this.queue.pause();
        this.state = { ...this.state, error: "PLAYBACK_REQUIRES_INTERACTION" };
        this.emit();
      });
    } else if (s.status !== "playing") {
      this.audio.pause();
      this.lastTick = 0;
    }
    if (s.status === "complete" || s.status === "failed") {
      this.persist();
      this.flushUsage();
      this.wakeProducer?.();
    }
    this.state = {
      ...this.state,
      status: s.status,
      paragraphId:
        segment?.paragraphId ??
        (s.status === "idle" ? null : this.state.paragraphId),
      range: segment
        ? {
            start: segment.sourceOffset,
            end:
              segment.sourceOffset +
              (segment.sourceLength ?? segment.text.length),
          }
        : null,
      seconds: segment ? this.audio.currentTime : 0,
      error: s.error,
    };
    this.emit();
  }
  private tick() {
    const s = this.queue.snapshot(),
      current = s.current;
    if (!current || !["playing", "paused"].includes(s.status)) return;
    const now = performance.now();
    if (
      s.status === "playing" &&
      !this.audio.paused &&
      !this.audio.ended &&
      this.audio.readyState >= 3
    ) {
      if (this.lastTick)
        this.usageSeconds += Math.min((now - this.lastTick) / 1000, 2);
      this.lastTick = now;
    } else this.lastTick = 0;
    if (this.usageSeconds >= 10) this.flushUsage();
    const word = this.words.find(
      (w) =>
        this.audio.currentTime >= w.startTime &&
        this.audio.currentTime < w.endTime,
    );
    const range = word?.range ?? {
      start: current.sourceOffset,
      end: current.sourceOffset + (current.sourceLength ?? current.text.length),
    };
    this.state = { ...this.state, range, seconds: this.audio.currentTime };
    this.emit();
    this.saveCheckpoint(
      word?.range.start ?? current.sourceOffset,
      this.audio.currentTime,
    );
    if (now - this.lastSave > 3000) this.persist();
  }
  private saveCheckpoint(offset: number, seconds: number) {
    const current = this.queue.snapshot().current;
    if (!this.doc || !current) return;
    this.checkpoint = {
      version: 1,
      accountScope: this.accountScope,
      documentId: this.doc.id,
      fingerprint: this.doc.fingerprint,
      paragraphId: current.paragraphId,
      sourceOffset: offset,
      segmentSeconds: seconds,
      mode: "read",
      updatedAt: new Date().toISOString(),
    };
  }
  private persist() {
    if (this.checkpoint) {
      void this.bridge.saveCheckpoint(this.checkpoint).catch(() => {
        this.state = { ...this.state, error: "PROGRESS_SAVE_FAILED" };
        this.emit();
      });
      this.lastSave = performance.now();
    }
  }
  private flushUsage() {
    const seconds = Math.floor(this.usageSeconds);
    if (!seconds) return;
    this.usageSeconds -= seconds;
    void this.bridge
      .track({ eventId: crypto.randomUUID(), seconds })
      .catch(() => {
        this.state = { ...this.state, error: "USAGE_SYNC_PENDING" };
        this.emit();
      });
  }
  private emit() {
    for (const listener of this.listeners) listener();
  }
}
export function readableError(error: unknown): string {
  const message = error instanceof Error ? error.message : "";
  return message.match(/\b[A-Z][A-Z0-9_]{3,80}\b/)?.[0] ?? "OPERATION_FAILED";
}
