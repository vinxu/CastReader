// Production commit: e8a755d4ea9602397cad138e6b3bbd3d91f7fa54
// Original repository path: src/shared/lib/tts-gateway.ts
// Original source lines 338–371
  const upstreamRoute = await resolveTTSUpstreamRoute(originalRequest);
  // Native partly clients allow 30 seconds to first response. Full-document
  // tools are a separate non-streaming contract and need a larger budget.
  const signal = speechRequestSignal(
    originalRequest?.signal,
    prepared.fullInput ? 90_000 : 28_000
  );
  const requestId =
    originalRequest?.headers.get('x-request-id')?.trim().slice(0, 128) ||
    randomUUID();
  const upstream = await retrySpeechRequest(
    async (attemptSignal) => {
      return fetch(upstreamRoute.url, {
        method: 'POST',
        redirect: 'error',
        headers: {
          accept: 'application/json',
          'content-type': 'application/json',
          'x-request-id': requestId,
        },
        // This gateway returns one complete JSON audio part to every client.
        // Kokoro defaults to NDJSON streaming when this flag is absent; its
        // final audio chunk can have no timestamps and must not be discarded.
        // Keep the existing text partition, but request all audio for that part.
        body: JSON.stringify({ ...payload, stream: false }),
        signal: AbortSignal.any([
          attemptSignal,
          AbortSignal.timeout(prepared.fullInput ? 65_000 : 20_000),
        ]),
      });
    },
    { signal }
  );


// Original source lines 476–498
export function gatewayError(error: unknown) {
  if (error instanceof Response) return error;
  if (error instanceof TTSRegionalConfigurationError) {
    console.error('[tts-gateway] regional routing rejected', {
      reason: error.message,
    });
    return Response.json(
      {
        code: 'TTS_REGIONAL_ROUTE_UNAVAILABLE',
        detail: 'Speech is temporarily unavailable',
      },
      { status: 503 }
    );
  }
  const isTimeout =
    error instanceof Error &&
    (error.name === 'TimeoutError' || error.name === 'AbortError');
  return Response.json(
    { detail: isTimeout ? 'TTS upstream timeout' : 'TTS upstream unavailable' },
    { status: isTimeout ? 504 : 502 }
  );
}

