import type { SourceRange, Timestamp } from "./types";

/** Mirrors the baseline preset wire/source contract, retaining UTF-16 offsets. */
export class SpeechProjection {
  readonly wire: string;
  private readonly ends: number[] = [];
  constructor(
    readonly source: string,
    limit = 5000,
  ) {
    const parts = [
      ...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(
        source,
      ),
    ];
    let first = 0;
    while (parts[first] && /^\s+$/u.test(parts[first]!.segment)) first++;
    let value = "";
    for (let i = first; i < parts.length; i++) {
      const part = parts[i]!;
      if (value.length + part.segment.length > limit) break;
      let end = part.index + part.segment.length;
      if (part.segment === "-") {
        while (parts[i + 1]?.segment === "-") {
          i++;
          end = parts[i]!.index + 1;
        }
      }
      value += part.segment;
      for (let j = 0; j < part.segment.length; j++) this.ends.push(end);
    }
    if ((this.ends.at(-1) ?? 0) < source.length) {
      const matches = [...value.matchAll(/\s/gu)];
      const boundary = matches.at(-1)?.index;
      if (boundary !== undefined && boundary >= value.length / 2) {
        value = value.slice(0, boundary + 1);
        this.ends.length = value.length;
      }
    }
    const consumed = this.ends.at(-1);
    value = value.trimEnd();
    this.ends.length = value.length;
    if (consumed !== undefined && this.ends.length)
      this.ends[this.ends.length - 1] = consumed;
    this.wire = value;
  }
  resolve(processed?: string | null, remaining?: string | null) {
    const prefix =
      processed ??
      (remaining != null && this.wire.endsWith(remaining)
        ? this.wire.slice(0, this.wire.length - remaining.length)
        : remaining == null
          ? this.wire
          : "");
    if (
      !prefix ||
      !this.wire.startsWith(prefix) ||
      (prefix.length < this.wire.length &&
        this.ends[prefix.length - 1] === this.ends[prefix.length])
    )
      throw new Error("TTS_SOURCE_MISMATCH");
    if (remaining != null && this.wire.slice(prefix.length) !== remaining)
      throw new Error("TTS_SOURCE_MISMATCH");
    let end = this.ends[prefix.length - 1];
    if (end === undefined) throw new Error("TTS_NO_PROGRESS");
    if (!this.source.slice(end).trim()) end = this.source.length;
    return {
      processed: this.source.slice(0, end),
      remaining: this.source.slice(end),
      consumed: end,
    };
  }
}

function normalizedMap(text: string): { text: string; ranges: SourceRange[] } {
  let normalized = "";
  const ranges: SourceRange[] = [];
  for (const part of new Intl.Segmenter(undefined, {
    granularity: "grapheme",
  }).segment(text)) {
    const value = part.segment
      .normalize("NFKC")
      .toLocaleLowerCase("en")
      .replace(/[\p{P}\p{Z}\s]/gu, "");
    normalized += value;
    for (let i = 0; i < value.length; i++)
      ranges.push({ start: part.index, end: part.index + part.segment.length });
  }
  return { text: normalized, ranges };
}

export interface AlignedWord {
  word: string;
  startTime: number;
  endTime: number;
  range: SourceRange;
}
export function alignWords(
  source: string,
  spoken: string,
  stamps: Timestamp[],
  offset = 0,
): AlignedWord[] {
  const original = normalizedMap(source.slice(offset)),
    speech = normalizedMap(spoken);
  if (!speech.text || !original.text.startsWith(speech.text)) return [];
  let cursor = 0;
  const result: AlignedWord[] = [];
  for (const stamp of stamps) {
    if (
      !Number.isFinite(stamp.start) ||
      !Number.isFinite(stamp.end) ||
      stamp.start < 0 ||
      stamp.end < stamp.start
    )
      return [];
    const token = normalizedMap(stamp.word).text;
    if (!token) continue;
    if (!speech.text.startsWith(token, cursor)) return [];
    const a = original.ranges[cursor],
      b = original.ranges[cursor + token.length - 1];
    if (!a || !b) return [];
    result.push({
      word: stamp.word,
      startTime: stamp.start,
      endTime: stamp.end,
      range: { start: offset + a.start, end: offset + b.end },
    });
    cursor += token.length;
  }
  return result;
}
