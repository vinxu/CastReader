import { describe, expect, it } from "vitest";
import { SpeechProjection, alignWords } from "../src/core/speech-projection";
import { PlaybackQueue } from "../src/core/playback-queue";
import { validateCheckpoint } from "../src/core/resume";
import { makeDocument } from "../src/core/documents";
import type { AudioSegment } from "../src/core/types";

const segment = (id: string): AudioSegment => ({
  id,
  paragraphId: "p-0",
  text: id,
  sourceOffset: 0,
  audio: "test",
  audioFormat: "mp3",
  timestamps: [],
  duration: 1,
});
describe("source projection", () => {
  it("maps collapsed hyphens and trimmed whitespace without dropping unread source", () => {
    const p = new SpeechProjection("  a---b next  ");
    expect(p.wire).toBe("a-b next");
    expect(p.resolve("a-b", " next")).toEqual({
      processed: "  a---b",
      remaining: " next  ",
      consumed: 7,
    });
    expect(p.resolve()).toEqual({
      processed: "  a---b next  ",
      remaining: "",
      consumed: 14,
    });
  });
  it("rejects a rewritten/contradictory continuation instead of skipping source", () => {
    const p = new SpeechProjection("Same same. Next.");
    expect(() => p.resolve("Next.", "")).toThrow("TTS_SOURCE_MISMATCH");
    expect(() => p.resolve("Same", "Next.")).toThrow("TTS_SOURCE_MISMATCH");
    expect(() => p.resolve("", p.wire)).toThrow();
  });
  it("does not split graphemes at the request limit", () => {
    const p = new SpeechProjection("ab👩‍💻next", 4);
    expect(p.wire).toBe("ab");
    expect(p.resolve().remaining).toBe("👩‍💻next");
  });
  it("rejects a service continuation inside a grapheme", () => {
    const p = new SpeechProjection("👩‍💻 next");
    expect(() => p.resolve("👩", "‍💻 next")).toThrow("TTS_SOURCE_MISMATCH");
  });
  it("maps repeated words sequentially, including normalized Unicode", () => {
    const source = "“Café,” café—CAFÉ.";
    const result = alignWords(
      source,
      "Café café CAFÉ",
      [0, 1, 2].map((n) => ({ word: "café", start: n, end: n + 0.8 })),
    );
    expect(result.map((r) => source.slice(r.range.start, r.range.end))).toEqual(
      ["Café", "café", "CAFÉ"],
    );
    expect(result.map((r) => r.range.start)).toEqual([1, 8, 13]);
  });
  it("fails closed on timing/text mismatches instead of jumping to a later duplicate", () => {
    expect(
      alignWords("one two one", "one two one", [
        { word: "two", start: 0, end: 1 },
      ]),
    ).toEqual([]);
    expect(
      alignWords("one", "one", [{ word: "one", start: 2, end: 1 }]),
    ).toEqual([]);
  });
});
describe("streaming playback ownership", () => {
  it("waits when audio outruns the producer and only ends after the producer finishes", () => {
    const q = new PlaybackQueue(),
      gen = q.begin();
    q.enqueue(gen, segment("a"));
    q.ended(gen, "a");
    expect(q.snapshot().status).toBe("buffering");
    q.enqueue(gen, segment("b"));
    q.finishGeneration(gen);
    expect(q.snapshot().status).toBe("playing");
    q.ended(gen, "b");
    expect(q.snapshot().status).toBe("complete");
  });
  it("new audio never undoes pause while buffering", () => {
    const q = new PlaybackQueue(),
      gen = q.begin();
    q.pause();
    q.enqueue(gen, segment("a"));
    expect(q.snapshot().status).toBe("paused");
    q.resume();
    expect(q.snapshot().status).toBe("playing");
  });
  it("drops late results and ended events from the previous document/account", () => {
    const q = new PlaybackQueue(),
      a = q.begin();
    q.enqueue(a, segment("a"));
    const b = q.begin();
    q.enqueue(b, segment("b"));
    q.ended(a, "a");
    q.fail(a, "old");
    expect(q.enqueue(a, segment("late"))).toBe(false);
    expect(q.snapshot().current?.id).toBe("b");
    q.stop();
    expect(q.enqueue(b, segment("late"))).toBe(false);
  });
  it("deduplicates audio and applies bounded backpressure", () => {
    const q = new PlaybackQueue(),
      gen = q.begin();
    q.enqueue(gen, segment("0"));
    expect(q.enqueue(gen, segment("0"))).toBe(false);
    for (let i = 1; i <= q.limit; i++) q.enqueue(gen, segment(String(i)));
    expect(() => q.enqueue(gen, segment("overflow"))).toThrow(
      "PLAYBACK_BACKPRESSURE",
    );
  });
});
describe("resume boundary", () => {
  it("does not transfer progress between accounts, edited documents or split Unicode", async () => {
    const doc = await makeDocument("Title", "a😀b");
    const c = {
      version: 1,
      accountScope: "global:A",
      documentId: doc.id,
      fingerprint: doc.fingerprint,
      paragraphId: "p-0",
      sourceOffset: 1,
      segmentSeconds: 0,
      mode: "read",
      updatedAt: new Date().toISOString(),
    };
    expect(validateCheckpoint(c, "global:A", doc)).not.toBeNull();
    expect(validateCheckpoint(c, "global:B", doc)).toBeNull();
    expect(
      validateCheckpoint(c, "global:A", { ...doc, fingerprint: "changed" }),
    ).toBeNull();
    expect(
      validateCheckpoint({ ...c, sourceOffset: 2 }, "global:A", doc),
    ).toBeNull();
    expect(
      validateCheckpoint({ ...c, segmentSeconds: NaN }, "global:A", doc),
    ).toBeNull();
  });
});
