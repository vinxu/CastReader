import { email, record, string } from "./validation";
import type { Account, Region, Timestamp } from "./types";

export type Fetcher = (url: string, init: RequestInit) => Promise<Response>;
export const routes = {
  global: {
    api: "https://api.castreader.ai",
    tts: "https://tts.castreader.ai",
    explain: "https://api.castreader.ai",
  },
  cn: {
    api: "https://api.castreader.cn",
    tts: "https://api.castreader.cn",
    explain: "https://quickread.castreader.cn",
  },
} as const;
export interface Session {
  account: Account;
  token: string;
  identityToken: string;
}
export interface Vault {
  read(): Session | null;
  write(session: Session | null): void;
}
export interface Entitlement {
  pro: boolean;
  plan?: string;
  listenRemaining?: number;
  freeRemaining?: number;
  resolvedUserId?: string;
}
export class ApiError extends Error {
  constructor(
    readonly code: string,
    readonly status = 0,
  ) {
    super(code);
  }
}

export async function json(
  fetcher: Fetcher,
  url: string,
  body?: unknown,
  token?: string,
  signal?: AbortSignal,
  method?: string,
): Promise<Record<string, unknown>> {
  const response = await fetcher(url, {
    method: method ?? (body === undefined ? "GET" : "POST"),
    credentials: "omit",
    redirect: "error",
    signal: signal ?? AbortSignal.timeout(45000),
    headers: {
      "Content-Type": "application/json",
      "X-Client-Platform": "windows",
      ...(token
        ? { Authorization: `Bearer ${token}`, "X-Auth-Provider": "session" }
        : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  if (!response.ok)
    throw new ApiError(`HTTP_${response.status}`, response.status);
  if (Number(response.headers.get("content-length") ?? 0) > 25000000)
    throw new ApiError("RESPONSE_TOO_LARGE");
  return record(await response.json());
}
const payload = (v: Record<string, unknown>) => (v.data ? record(v.data) : v);
const validSession = (value: string) =>
  value.startsWith("cms_") &&
  !value.startsWith("cms_local_") &&
  value.length > 4 &&
  value.length <= 4096 &&
  value.trim() === value;

export class AccountService {
  private session: Session | null;
  private epoch = 0;
  private refreshWork: Promise<Session> | null = null;
  constructor(
    private fetcher: Fetcher,
    private vault: Vault,
    readonly deviceId: string,
    private appVersion: string,
  ) {
    this.session = vault.read();
  }
  get account() {
    return this.session?.account ?? null;
  }
  get scope() {
    return this.account ? `${this.account.region}:${this.account.id}` : null;
  }
  get generation() {
    return this.epoch;
  }
  private assert(epoch: number) {
    if (epoch !== this.epoch) throw new ApiError("ACCOUNT_CHANGED");
  }
  async sendCode(address: string, region: Region) {
    await json(
      this.fetcher,
      routes[region].api + "/api/auth/email-otp/send-verification-otp",
      { email: email(address), type: "sign-in" },
    );
  }
  async signIn(address: string, otp: string, region: Region): Promise<Account> {
    const epoch = ++this.epoch,
      normalized = email(address);
    const result = await json(
      this.fetcher,
      routes[region].api + "/api/auth/sign-in/email-otp",
      { email: normalized, otp: string(otp, 32).trim() },
    );
    this.assert(epoch);
    const user = record(result.user),
      id = string(user.id, 256),
      identityToken = string(result.token, 8192);
    if (!id.trim() || !identityToken.trim())
      throw new ApiError("INVALID_IDENTITY");
    const session = payload(
      await json(
        this.fetcher,
        routes[region].api + "/api/mobile-auth/session",
        { provider: "email", idToken: identityToken, deviceId: this.deviceId },
      ),
    );
    this.assert(epoch);
    if (
      session.userId !== id ||
      typeof session.token !== "string" ||
      !validSession(session.token)
    )
      throw new ApiError("INVALID_SESSION");
    const account: Account = {
      id,
      email: normalized,
      displayName:
        typeof user.name === "string" && user.name.trim()
          ? user.name
          : normalized.split("@")[0]!,
      region,
    };
    const next = { account, token: session.token, identityToken };
    this.vault.write(next);
    this.session = next;
    return account;
  }
  async signOut() {
    const old = this.session;
    ++this.epoch;
    this.session = null;
    this.refreshWork = null;
    this.vault.write(null);
    if (old) {
      try {
        await json(
          this.fetcher,
          routes[old.account.region].api + "/api/mobile-auth/session",
          undefined,
          old.token,
          undefined,
          "DELETE",
        );
      } catch {
        /* local boundary is authoritative; server expiry still applies */
      }
    }
  }
  private async refresh(old: Session, epoch: number): Promise<Session> {
    if (this.refreshWork) return this.refreshWork;
    const work = (async () => {
      const result = payload(
        await json(
          this.fetcher,
          routes[old.account.region].api + "/api/mobile-auth/session",
          {
            provider: "email",
            idToken: old.identityToken,
            deviceId: this.deviceId,
          },
        ),
      );
      this.assert(epoch);
      if (
        result.userId !== old.account.id ||
        typeof result.token !== "string" ||
        !validSession(result.token)
      )
        throw new ApiError("INVALID_SESSION");
      const next = { ...old, token: result.token };
      this.vault.write(next);
      this.session = next;
      return next;
    })();
    this.refreshWork = work;
    try {
      return await work;
    } finally {
      if (this.refreshWork === work) this.refreshWork = null;
    }
  }
  async request(
    path: string,
    body?: unknown,
  ): Promise<Record<string, unknown>> {
    if (!this.session) throw new ApiError("SIGN_IN_REQUIRED");
    const old = this.session,
      epoch = this.epoch;
    const request = (session: Session) =>
      json(
        this.fetcher,
        routes[session.account.region].api + path,
        body,
        session.token,
      );
    try {
      const result = await request(old);
      this.assert(epoch);
      return result;
    } catch (error) {
      this.assert(epoch);
      if (!(error instanceof ApiError) || error.status !== 401) throw error;
      try {
        const fresh =
          this.session !== old ? this.session! : await this.refresh(old, epoch);
        const result = await request(fresh);
        this.assert(epoch);
        return result;
      } catch (retryError) {
        this.assert(epoch);
        if (
          retryError instanceof ApiError &&
          (retryError.status === 401 || retryError.code === "INVALID_SESSION")
        ) {
          ++this.epoch;
          this.session = null;
          this.vault.write(null);
        }
        throw retryError;
      }
    }
  }
  async status(): Promise<Entitlement> {
    const scope = this.scope,
      day = new Date(),
      localDate = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, "0")}-${String(day.getDate()).padStart(2, "0")}`;
    const query = new URLSearchParams({
      device_id: this.deviceId,
      analytics_anonymous_id: this.deviceId,
      local_date: localDate,
      app_version: this.appVersion,
    });
    const data = payload(
      await this.request("/api/mobile/pro/status/v2?" + query),
    );
    if (
      scope !== this.scope ||
      typeof data.pro !== "boolean" ||
      (data.resolvedUserId && data.resolvedUserId !== this.account?.id)
    )
      throw new ApiError("INVALID_ENTITLEMENT");
    for (const key of ["listenRemaining", "freeRemaining"])
      if (
        data[key] !== undefined &&
        data[key] !== null &&
        (typeof data[key] !== "number" || !Number.isFinite(data[key]))
      )
        throw new ApiError("INVALID_ENTITLEMENT");
    return {
      pro: data.pro,
      plan: typeof data.plan === "string" ? data.plan : undefined,
      listenRemaining:
        typeof data.listenRemaining === "number"
          ? data.listenRemaining
          : undefined,
      freeRemaining:
        typeof data.freeRemaining === "number" ? data.freeRemaining : undefined,
      resolvedUserId: this.account!.id,
    };
  }
  async track(eventId: string, seconds: number) {
    return this.request("/api/mobile/pro/listen-track/v2", {
      analytics_anonymous_id: this.deviceId,
      usage_event_id: eventId,
      seconds,
    });
  }
}

export interface SpeechResult {
  audio: string;
  audioFormat: "mp3" | "wav";
  timestamps: Timestamp[];
  duration: number;
  processed?: string;
  remaining?: string;
}
export async function synthesize(
  fetcher: Fetcher,
  input: {
    text: string;
    voice: string;
    language: string;
    region: Region;
    requestId: string;
  },
  signal: AbortSignal,
): Promise<SpeechResult> {
  if (
    input.text.length > 5000 ||
    !input.text.trim() ||
    !/^[a-z0-9_-]{1,100}$/i.test(input.voice) ||
    /^(vc_|vl_)/.test(input.voice)
  )
    throw new ApiError("INVALID_SPEECH_REQUEST");
  const init: RequestInit = {
    method: "POST",
    credentials: "omit",
    redirect: "error",
    signal,
    headers: {
      "Content-Type": "application/json",
      "X-Client-Platform": "windows",
      "X-Request-ID": input.requestId,
    },
    body: JSON.stringify({
      model: "kokoro",
      input: input.text,
      voice: input.voice,
      voice_code: input.voice,
      response_format: "mp3",
      return_timestamps: !["zh", "ja", "ko"].includes(
        input.language.split("-")[0]!,
      ),
      speed: 1,
      stream: false,
      language: input.language,
    }),
  };
  let response = await fetcher(
    routes[input.region].tts + "/api/captioned_speech_partly",
    init,
  );
  // No retry after ambiguous transport failures: synthesis may already be billable.
  if (
    input.region === "global" &&
    response.status === 503 &&
    response.headers.get("x-castreader-tts-contract") === "preset-gateway-v1" &&
    response.headers.get("x-castreader-tts-attempts") === "0" &&
    response.headers.get("x-tts-error-code") === "TTS_GATEWAY_BUSY" &&
    response.headers.get("x-voice-retryable") === "true"
  ) {
    await response.body?.cancel();
    response = await fetcher(
      routes.global.api + "/api/captioned_speech_partly",
      init,
    );
  }
  if (!response.ok)
    throw new ApiError(`TTS_HTTP_${response.status}`, response.status);
  if (Number(response.headers.get("content-length") ?? 0) > 25000000)
    throw new ApiError("AUDIO_TOO_LARGE");
  const result = record(await response.json()),
    audio = string(result.audio, 25000000);
  if (!audio || !/^[A-Za-z0-9+/=\r\n]+$/.test(audio))
    throw new ApiError("INVALID_AUDIO");
  if (result.voice_code !== undefined && result.voice_code !== input.voice)
    throw new ApiError("VOICE_MISMATCH");
  const stamps: Timestamp[] = [];
  if (Array.isArray(result.timestamps))
    for (const t of result.timestamps) {
      if (!t || typeof t !== "object") continue;
      const start = t.start ?? t.start_time,
        end = t.end ?? t.end_time;
      if (
        typeof t.word === "string" &&
        Number.isFinite(start) &&
        Number.isFinite(end) &&
        start >= 0 &&
        end >= start
      )
        stamps.push({ word: t.word, start, end });
    }
  return {
    audio,
    audioFormat: result.audio_format === "wav" ? "wav" : "mp3",
    timestamps: stamps,
    duration:
      typeof result.duration === "number" && Number.isFinite(result.duration)
        ? result.duration
        : 0,
    processed:
      result.processed_text == null
        ? undefined
        : string(result.processed_text, 5000),
    remaining:
      result.unprocessed_text == null
        ? undefined
        : string(result.unprocessed_text, 5000),
  };
}
