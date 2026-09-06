// Production commit: e8a755d4ea9602397cad138e6b3bbd3d91f7fa54
// Original repository path: src/app/api/captioned_speech_partly/route.ts
import { after } from 'next/server';

import {
  gatewayError,
  proxyTtsPayload,
  readTtsPayload,
  ttsUpstreamRouteHeaders,
} from '@/shared/lib/tts-gateway';
import { resolveTTSUpstreamRoute } from '@/shared/ops/tts-upstream-routing-store';

export const maxDuration = 300;
export const dynamic = 'force-dynamic';

// Release probes verify the effective route before sending any synthesis text.
export async function HEAD(request: Request) {
  try {
    const route = await resolveTTSUpstreamRoute(request);
    return new Response(null, {
      headers: {
        'Cache-Control': 'no-store',
        ...ttsUpstreamRouteHeaders(route),
      },
    });
  } catch (error) {
    return gatewayError(error);
  }
}

export async function POST(request: Request) {
  try {
    const payload = await readTtsPayload(request);
    return await proxyTtsPayload(payload, request, (task) => after(task));
  } catch (error) {
    return gatewayError(error);
  }
}

