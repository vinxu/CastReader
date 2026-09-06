// Production commit: e8a755d4ea9602397cad138e6b3bbd3d91f7fa54
// Original repository path: src/shared/lib/speech-request-budget.ts
import { setTimeout as delay } from 'node:timers/promises';

export const SPEECH_REQUEST_BUDGET_MS = 90_000;

/** One deadline for attempts, response bodies, backoff and voice restoration. */
export function speechRequestSignal(
  parent?: AbortSignal,
  budgetMs = SPEECH_REQUEST_BUDGET_MS
) {
  const deadline = AbortSignal.timeout(budgetMs);
  return parent ? AbortSignal.any([parent, deadline]) : deadline;
}

export async function withinSpeechBudget<T>(
  operation: Promise<T>,
  signal: AbortSignal
): Promise<T> {
  signal.throwIfAborted();
  let onAbort: (() => void) | undefined;
  try {
    return await Promise.race([
      operation,
      new Promise<never>((_, reject) => {
        onAbort = () => reject(signal.reason);
        signal.addEventListener('abort', onAbort, { once: true });
      }),
    ]);
  } finally {
    if (onAbort) signal.removeEventListener('abort', onAbort);
  }
}

const TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);

function explicitBusinessDenial(response: Response) {
  const code =
    response.headers.get('x-voice-error-code') ||
    response.headers.get('x-tts-error-code') ||
    '';
  return (
    /(?:QUOTA|ENTITLEMENT|SUBSCRIPTION|PRO_REQUIRED)/i.test(code) ||
    (response.status === 429 &&
      response.headers.has('x-clone-quota-limit-seconds'))
  );
}

export async function retrySpeechRequest(
  request: (signal: AbortSignal) => Promise<Response>,
  options: {
    signal?: AbortSignal;
    budgetMs?: number;
    retryDelaysMs?: readonly number[];
  } = {}
): Promise<Response> {
  const signal = speechRequestSignal(options.signal, options.budgetMs);
  const delays = options.retryDelaysMs ?? [500, 1_500];
  for (let attempt = 0; ; attempt += 1) {
    signal.throwIfAborted();
    let retryAfterMs: number | undefined;
    try {
      const response = await withinSpeechBudget(request(signal), signal);
      if (response.ok) {
        // A 200 header is not a usable audio result. Include the complete body
        // (and JSON framing for captioned speech) in the same retry attempt.
        const body = await withinSpeechBudget(response.arrayBuffer(), signal);
        if (
          response.headers.get('content-type')?.split(';', 1)[0].trim() ===
          'application/json'
        ) {
          JSON.parse(Buffer.from(body).toString('utf8'));
        }
        return new Response(body, {
          status: response.status,
          headers: response.headers,
        });
      }
      if (
        !TRANSIENT_STATUSES.has(response.status) ||
        explicitBusinessDenial(response) ||
        response.headers.get('x-voice-retryable')?.toLowerCase() === 'false' ||
        attempt >= delays.length
      )
        return response;
      const retryAfter = Number(response.headers.get('retry-after'));
      if (Number.isFinite(retryAfter) && retryAfter > 0) {
        retryAfterMs = Math.min(retryAfter * 1_000, 8_000);
      }
      // Release the failed response before opening another connection. Every
      // attempt uses the same URL, voice and request ID supplied by the caller.
      await withinSpeechBudget(response.arrayBuffer(), signal);
    } catch (error) {
      signal.throwIfAborted();
      if (attempt >= delays.length) throw error;
    }
    await delay(retryAfterMs ?? delays[attempt], undefined, { signal });
  }
}

