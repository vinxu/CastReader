import type { AudioSegment } from "./types";
export type PlaybackStatus =
  "idle" | "buffering" | "playing" | "paused" | "complete" | "failed";
export interface PlaybackSnapshot {
  generation: number;
  status: PlaybackStatus;
  current: AudioSegment | null;
  queued: number;
  expecting: boolean;
  error: string | null;
}

/** Generation gates prevent a canceled document/voice/account from resuming playback. */
export class PlaybackQueue {
  private generation = 0;
  private queue: AudioSegment[] = [];
  private current: AudioSegment | null = null;
  private expecting = false;
  private wantsPlayback = false;
  private status: PlaybackStatus = "idle";
  private error: string | null = null;
  private seen = new Set<string>();
  readonly limit = 6;
  snapshot(): PlaybackSnapshot {
    return {
      generation: this.generation,
      status: this.status,
      current: this.current,
      queued: this.queue.length,
      expecting: this.expecting,
      error: this.error,
    };
  }
  begin(play = true) {
    this.generation++;
    this.queue = [];
    this.current = null;
    this.seen.clear();
    this.error = null;
    this.expecting = true;
    this.wantsPlayback = play;
    this.status = play ? "buffering" : "paused";
    return this.generation;
  }
  enqueue(generation: number, segment: AudioSegment): boolean {
    if (
      generation !== this.generation ||
      !this.expecting ||
      this.seen.has(segment.id)
    )
      return false;
    if (this.queue.length >= this.limit)
      throw new Error("PLAYBACK_BACKPRESSURE");
    this.seen.add(segment.id);
    this.queue.push(segment);
    this.advance();
    return true;
  }
  finishGeneration(generation: number) {
    if (generation === this.generation) {
      this.expecting = false;
      this.advance();
    }
  }
  pause() {
    this.wantsPlayback = false;
    if (!["idle", "complete", "failed"].includes(this.status))
      this.status = "paused";
  }
  resume() {
    if (["idle", "complete", "failed"].includes(this.status)) return;
    this.wantsPlayback = true;
    this.advance();
  }
  ended(generation: number, segmentId: string) {
    if (generation !== this.generation || this.current?.id !== segmentId)
      return;
    this.current = null;
    this.advance();
  }
  fail(generation: number, code: string) {
    if (generation !== this.generation) return;
    this.queue = [];
    this.current = null;
    this.expecting = false;
    this.wantsPlayback = false;
    this.error = code;
    this.status = "failed";
  }
  stop() {
    this.begin(false);
    this.expecting = false;
    this.status = "idle";
  }
  private advance() {
    if (!this.current && this.queue.length) this.current = this.queue.shift()!;
    if (!this.current && !this.expecting) {
      this.status = "complete";
      this.wantsPlayback = false;
      return;
    }
    this.status = this.wantsPlayback
      ? this.current
        ? "playing"
        : "buffering"
      : "paused";
  }
}
