import { createOriginFollower } from './origin-follow.mjs';
import { createHash, randomUUID } from 'node:crypto';
import http from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 7778;
// This same-US proxy stays available while its model workers drain and switch.
export const DEFAULT_UPSTREAM =
  'http://71.175.237.66:41209/dev/captioned_speech';
const LEGACY_UPSTREAM = 'http://71.175.237.66:41228/dev/captioned_speech';
const MAX_BODY_BYTES = 64 * 1024;
const MAX_INPUT_CHARACTERS = 10_000;
const MAX_UPSTREAM_RESPONSE_BYTES = 16 * 1024 * 1024;
const DEFAULT_MAX_IN_FLIGHT = 16;
export const UPSTREAM_TIMEOUT_MS = 120_000;
export const GATEWAY_CONTRACT = 'preset-gateway-v1';
export const REQUEST_POLICIES = Object.freeze({
  legacy: Object.freeze({ budgetMs: 120_000, attemptTimeoutMs: 120_000 }),
  'extension-v1': Object.freeze({ budgetMs: 28_000, attemptTimeoutMs: 20_000 }),
});

function jsonResponse(response, status, body, headers = {}) {
  if (response.destroyed || response.writableEnded) return;
  const data = Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    'cache-control': 'no-store',
    'content-length': String(data.length),
    'content-type': 'application/json; charset=utf-8',
    'x-castreader-gateway': 'direct-us',
    ...headers,
  });
  response.end(data);
}

// BEGIN canonical preset text compatibility
// Source: scmyyan/readout-web @ 7481f167 (2026-09-07 Global release).
// tts-sentence-boundary.ts SHA-256: 9c675e9162145ec5eed0b0470602eb3f44db2f581eee897452a16ea76c7d6cc3
// tts-gateway.ts SHA-256: 93a0d06edf3bbfbf3eceea58d0c2eae1f4bbbcc130e3f1e59e1b3874039abb1c
// Keep helpers inline for the existing single-file deployment. Verify against
// the pinned sources with gateway-canonical-parity.test.mjs before changing them.
const MAX_UPSTREAM_CHARACTERS = 900;
const MAX_ENGLISH_UPSTREAM_WORDS = 74;
const SENTENCE_TERMINATORS = new Set([
    '.',
    '!',
    '?',
    ';',
    '。',
    '！',
    '？',
    '；',
    '～',
    '…',
    '।',
    '॥'
]);
const SENTENCE_CLOSERS = new Set([
    '"',
    "'",
    '»',
    '’',
    '”',
    ')',
    ']',
    '）',
    '】',
    '」',
    '』',
    '〉',
    '》'
]);
const PERIOD_ABBREVIATIONS = new Set([
    'abb',
    'apr',
    'aug',
    'bsp',
    'bzw',
    'ca',
    'capt',
    'cmdr',
    'co',
    'col',
    'corp',
    'dec',
    'dept',
    'dr',
    'e.g',
    'eq',
    'etc',
    'feb',
    'fig',
    'fr',
    'ft',
    'gen',
    'ggf',
    'hon',
    'i.e',
    'inc',
    'inkl',
    'jan',
    'jr',
    'jul',
    'jun',
    'kap',
    'lt',
    'ltd',
    'mar',
    'mr',
    'mrs',
    'ms',
    'mt',
    'mx',
    'no',
    'nov',
    'nr',
    'oct',
    'p.m',
    'ph.d',
    'prof',
    'rev',
    's',
    'sep',
    'sept',
    'sgt',
    'sog',
    'sr',
    'st',
    'u',
    'u.k',
    'u.s',
    'usw',
    'vgl',
    'vol',
    'vs',
    'z',
    'a.m'
]);
const PROTECTED_INLINE_ADDRESS_PATTERNS = [
    /(?:https?:\/\/|www\.)[^\s<>"'。！？；…]+/giu,
    /[\p{L}\p{M}\p{N}._%+-]+@[\p{L}\p{M}\p{N}.-]+\.[\p{L}\p{M}]{2,}/giu,
    /(?:[\p{L}\p{M}\p{N}-]+\.)+[\p{L}\p{M}]{2,}(?::\d{1,5})?(?:[/?#][^\s<>"'。！？；…]*)?/giu
];
const GRAPHEME_SEGMENTER = new Intl.Segmenter('und', {
    granularity: 'grapheme'
});
function absorbWhitespace(input, offset) {
    let end = offset;
    while(end < input.length && /\s/u.test(input[end]))end += 1;
    return end;
}
function protectedInlineAddressRanges(input) {
    const ranges = [];
    for (const pattern of PROTECTED_INLINE_ADDRESS_PATTERNS){
        pattern.lastIndex = 0;
        for (const match of input.matchAll(pattern)){
            const start = match.index;
            let end = start + match[0].length;
            while(end > start && /[.,!?;:]/u.test(input[end - 1]))end -= 1;
            if (end > start) ranges.push({
                start,
                end
            });
        }
    }
    return ranges;
}
function rangeContains(ranges, offset) {
    return ranges.some(({ start, end })=>offset >= start && offset < end);
}
function periodTokenBefore(input, offset) {
    let start = offset;
    while(start > 0 && /[\p{L}\p{M}\p{N}.]/u.test(input[start - 1])){
        start -= 1;
    }
    return {
        start,
        token: input.slice(start, offset).normalize('NFKC').toLocaleLowerCase('und').replace(/^\.+|\.+$/gu, '')
    };
}
function hasReadableText(input) {
    return /[\p{L}\p{M}\p{N}]/u.test(input);
}
function isProtectedPeriod(input, offset, protectedRanges) {
    if (rangeContains(protectedRanges, offset)) return true;
    const previous = input[offset - 1] || '';
    const next = input[offset + 1] || '';
    if (/\p{N}/u.test(previous) && /\p{N}/u.test(next)) return true;
    if (/[\p{Script=Latin}\p{N}]/u.test(previous) && /[\p{Script=Latin}\p{N}]/u.test(next)) {
        return true;
    }
    let lookahead = offset + 1;
    while(lookahead < input.length && SENTENCE_CLOSERS.has(input[lookahead])){
        lookahead += 1;
    }
    while(lookahead < input.length && /[\t \f\v\u00a0]/u.test(input[lookahead])){
        lookahead += 1;
    }
    if (lookahead >= input.length || /[\r\n]/u.test(input[lookahead])) {
        return false;
    }
    const { start: tokenStart, token } = periodTokenBefore(input, offset);
    if (PERIOD_ABBREVIATIONS.has(token)) return true;
    if (/^\p{L}$/u.test(token)) return true;
    if (/^(?:\p{L}\.)+\p{L}$/u.test(token)) return true;
    if (/^\p{N}+$/u.test(token)) return true;
    return /^(?:\p{N}+\.)+\p{N}+$/u.test(token) && !hasReadableText(input.slice(0, tokenStart));
}
function canEndSentenceBefore(input, offset, lineEnd) {
    if (offset >= lineEnd) return true;
    const next = input[offset];
    return /\s/u.test(next) || /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Devanagari}]/u.test(next);
}
function naturalSentenceCuts(input, lineEnd) {
    const scanEnd = Math.min(lineEnd, MAX_UPSTREAM_CHARACTERS);
    const protectedRanges = protectedInlineAddressRanges(input.slice(0, scanEnd));
    const cuts = [];
    let offset = 0;
    while(offset < scanEnd){
        const character = input[offset];
        if (!SENTENCE_TERMINATORS.has(character) || rangeContains(protectedRanges, offset)) {
            offset += 1;
            continue;
        }
        let terminalEnd = offset + 1;
        while(terminalEnd < lineEnd && SENTENCE_TERMINATORS.has(input[terminalEnd])){
            terminalEnd += 1;
        }
        const terminalRun = input.slice(offset, terminalEnd);
        if (terminalRun === '.' && isProtectedPeriod(input, offset, protectedRanges)) {
            offset = terminalEnd;
            continue;
        }
        let sentenceEnd = terminalEnd;
        while(sentenceEnd < lineEnd && SENTENCE_CLOSERS.has(input[sentenceEnd])){
            sentenceEnd += 1;
        }
        if (canEndSentenceBefore(input, sentenceEnd, lineEnd)) {
            const cut = absorbWhitespace(input, sentenceEnd);
            if (hasReadableText(input.slice(0, cut))) cuts.push(cut);
        }
        offset = terminalEnd;
    }
    return [
        ...new Set(cuts)
    ].sort((left, right)=>left - right);
}
function englishWordCount(input) {
    return input.match(/\S+/gu)?.length || 0;
}
function upstreamCharacterCount(input) {
    return input.trim().length;
}
function safeGraphemeCut(input, offset) {
    if (offset <= 0 || offset >= input.length) return offset;
    let boundary = 0;
    for (const segment of GRAPHEME_SEGMENTER.segment(input)){
        const end = segment.index + segment.segment.length;
        if (end > offset) break;
        boundary = end;
    }
    return boundary || offset;
}
function hardCompatibilityCut(input, upperBound, language) {
    let limit = Math.min(upperBound, MAX_UPSTREAM_CHARACTERS);
    if (language === 'en') {
        const words = [
            ...input.slice(0, upperBound).matchAll(/\S+/gu)
        ];
        const firstExcludedWord = words[MAX_ENGLISH_UPSTREAM_WORDS];
        if (firstExcludedWord?.index !== undefined) {
            limit = Math.min(limit, firstExcludedWord.index);
        }
    }
    limit = safeGraphemeCut(input, limit);
    if (limit >= upperBound) return upperBound;
    let whitespaceStart = limit;
    while(whitespaceStart > 0 && !/\s/u.test(input[whitespaceStart - 1])){
        whitespaceStart -= 1;
    }
    if (whitespaceStart > 0) return absorbWhitespace(input, whitespaceStart);
    return Math.max(1, limit);
}
export function splitTtsInputForCompatibility(input, language) {
    const newlineOffset = input.search(/[\r\n]/u);
    const lineEnd = newlineOffset === -1 ? input.length : newlineOffset;
    const lineCut = lineEnd < input.length ? absorbWhitespace(input, lineEnd) : lineEnd;
    const naturalCuts = naturalSentenceCuts(input, lineEnd);
    let cut = input.length;
    if (language !== 'en') {
        cut = naturalCuts[0] ?? lineCut;
    } else {
        const candidates = [
            ...new Set([
                ...naturalCuts,
                lineCut
            ])
        ].sort((left, right)=>left - right);
        let selected = 0;
        for (const candidate of candidates){
            if (upstreamCharacterCount(input.slice(0, candidate)) > MAX_UPSTREAM_CHARACTERS || englishWordCount(input.slice(0, candidate)) > MAX_ENGLISH_UPSTREAM_WORDS) {
                break;
            }
            selected = candidate;
        }
        cut = selected || hardCompatibilityCut(input, lineCut, language);
    }
    if (upstreamCharacterCount(input.slice(0, cut)) > MAX_UPSTREAM_CHARACTERS || language === 'en' && englishWordCount(input.slice(0, cut)) > MAX_ENGLISH_UPSTREAM_WORDS) {
        cut = hardCompatibilityCut(input, cut, language);
    }
    cut = Math.min(Math.max(1, cut), input.length);
    return {
        processed: input.slice(0, cut),
        unprocessed: input.slice(cut)
    };
}
const UNAMBIGUOUS_PRESET_LANGUAGE_BY_PREFIX = {
    af: 'en',
    am: 'en',
    bf: 'en',
    bm: 'en',
    df: 'de',
    dm: 'de',
    ff: 'fr',
    fm: 'fr',
    hf: 'hi',
    hm: 'hi',
    if: 'it',
    im: 'it',
    jf: 'ja',
    jm: 'ja',
    pf: 'pt',
    pm: 'pt',
    zf: 'zh',
    zm: 'zh'
};
const INLINE_NUMERIC_CITATION_PATTERN = /(?<![\p{L}\p{M}\p{N}_])\[(?:\d{1,4}(?:\s*[-–,]\s*\d{1,4})*)\]/gu;
const PUNCTUATION_ONLY_SILENCE_MP3 = '//NExAAAAANIAAAAAExBTUUzLjEwMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTMu//NExFMAAANIAAAAADEwMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTMu//NExKYAAANIAAAAADEwMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTMu//NExKwAAANIAAAAADEwMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTMu//NExKwAAANIAAAAADEwMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//NExKwAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//NExKwAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV';
function isPunctuationOnly(input) {
    return /^[\p{P}\p{M}\s]+$/u.test(input);
}
export function inferLanguageFromPresetVoice(voice) {
    if (typeof voice !== 'string') return undefined;
    const match = voice.trim().toLowerCase().match(/^([a-z]{2})_/u);
    return match ? UNAMBIGUOUS_PRESET_LANGUAGE_BY_PREFIX[match[1]] : undefined;
}
export function stripInlineNumericCitations(input) {
    return input.replace(INLINE_NUMERIC_CITATION_PATTERN, ' ').replace(/\s+([,.;:!?。，！？；：])/gu, '$1').replace(/\s+/gu, ' ').trim();
}

// END canonical preset text compatibility

// BEGIN canonical playback timing compatibility
// Generated by sync-canonical-timing.mjs from readout-web @ 7481f1670ec6e9b9a51a72ada8f3cc114920f296.
// tts-response-timing.ts SHA-256: 848b412143d996824e7140a7117c19394534830f2a7b9adc47c78ec14a37e605
export function playbackTimestamps(value) {
    if (!Array.isArray(value)) return [];
    let previousStart = 0;
    let previousEnd = 0;
    for (const timestamp of value){
        if (!timestamp || typeof timestamp.word !== 'string' || !timestamp.word.trim() || typeof timestamp.start_time !== 'number' || typeof timestamp.end_time !== 'number' || !Number.isFinite(timestamp.start_time) || !Number.isFinite(timestamp.end_time) || timestamp.start_time < 0 || timestamp.end_time <= timestamp.start_time || timestamp.start_time + 0.001 < previousStart || timestamp.end_time + 0.001 < previousEnd) {
            return [];
        }
        previousStart = timestamp.start_time;
        previousEnd = timestamp.end_time;
    }
    return value;
}
function readableCoverageTokens(input) {
    return input.match(/[\p{L}\p{M}\p{N}]+(?:[’'\-][\p{L}\p{M}\p{N}]+)*/gu) || [];
}
function canonicalCoverageToken(input) {
    return input.normalize('NFKC').toLocaleLowerCase('und').replace(/[^\p{L}\p{M}\p{N}]+/gu, '');
}
export function timestampsCoverEnglishInput(input, timestamps) {
    const expected = readableCoverageTokens(input);
    if (expected.length === 0) return true;
    if (!Array.isArray(timestamps)) return false;
    const actual = readableCoverageTokens(timestamps.map((timestamp)=>timestamp && typeof timestamp === 'object' && typeof timestamp.word === 'string' ? String(timestamp.word) : '').join(' '));
    if (actual.length === 0) return false;
    const expectedStableTail = [
        ...expected
    ].reverse().find((token)=>/[\p{L}\p{M}]/u.test(token) && !/[\p{N}]/u.test(token));
    const actualTail = actual.slice(-16).map(canonicalCoverageToken);
    const hasStableTail = expectedStableTail ? actualTail.includes(canonicalCoverageToken(expectedStableTail)) : true;
    if (expected.length < 8) {
        return actual.length >= expected.length && hasStableTail;
    }
    const coverageRatio = actual.length / expected.length;
    return coverageRatio >= 0.85 && hasStableTail;
}
// END canonical playback timing compatibility

export function normalizeTimestampAliases(value) {
  if (!Array.isArray(value)) return [];
  return value.map(timestamp => {
    if (!timestamp || typeof timestamp !== 'object' || Array.isArray(timestamp)) return null;
    const { start, end, ...rest } = timestamp;
    // Standard fields win when finite. Remove aliases after normalization so
    // clients with different alias precedence cannot disagree on the clock.
    return { ...rest,
      start_time: Number.isFinite(rest.start_time) ? rest.start_time : start,
      end_time: Number.isFinite(rest.end_time) ? rest.end_time : end,
    };
  });
}

export function splitForCompatibility(input, language) {
  return splitTtsInputForCompatibility(input, language);
}

export function preparePayload(payload) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return { error: { status: 400, detail: 'Invalid JSON body' } };
  }
  if (typeof payload.input !== 'string' || !payload.input.trim()) {
    return { error: { status: 400, detail: 'input is required' } };
  }
  if (payload.input.length > MAX_INPUT_CHARACTERS) {
    return { error: { status: 413, detail: 'input exceeds 10000 characters' } };
  }

  const requestedVoice = payload.voice ?? payload.voice_code;
  if (typeof requestedVoice === 'string' && requestedVoice.startsWith('vc_')) {
    return {
      error: {
        status: 501,
        body: {
          code: 'VOICE_CLONE_REQUIRES_LEGACY_GATEWAY',
          message: 'Cloned voices are not available on this gateway',
        },
      },
    };
  }

  const normalizedInput = payload.input.trim().replace(/-+/g, '-');
  const language = String(
    payload.language || inferLanguageFromPresetVoice(requestedVoice) || 'en'
  )
    .trim()
    .toLowerCase()
    .replace('_', '-')
    .split('-', 1)[0];
  const { processed, unprocessed } = splitForCompatibility(
    normalizedInput,
    language
  );
  // This endpoint returns one complete audio segment to existing mobile clients.
  // Kokoro's default streaming response contains several audio documents; taking
  // the first one silently loses the rest of the selected text's audio.
  const upstreamPayload = {
    ...payload,
    input: stripInlineNumericCitations(processed),
    language,
    stream: false,
  };
  if (
    !upstreamPayload.voice &&
    typeof upstreamPayload.voice_code === 'string'
  ) {
    upstreamPayload.voice = upstreamPayload.voice_code;
  }

  return {
    payload: upstreamPayload,
    processedText: unprocessed ? processed : undefined,
    unprocessedText: unprocessed || undefined,
    voiceCode:
      typeof requestedVoice === 'string' && requestedVoice
        ? requestedVoice
        : undefined,
  };
}

async function readRequestBody(request) {
  // Throwing inside IncomingMessage's async iterator destroys the socket before
  // a 413 can be sent. Stop retaining bytes, drain, then close after the reply.
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    const cleanup = () => {
      request.off('data', onData);
      request.off('end', onEnd);
      request.off('error', onError);
      request.off('aborted', onAborted);
    };
    const onError = (error) => { cleanup(); reject(error); };
    const onAborted = () => onError(new Error('request body closed'));
    const onEnd = () => { cleanup(); resolve(Buffer.concat(chunks).toString('utf8')); };
    const onData = (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        const error = new Error('request body too large');
        error.status = 413;
        cleanup();
        request.resume();
        reject(error);
        return;
      }
      chunks.push(chunk);
    };
    request.on('data', onData);
    request.once('end', onEnd);
    request.once('error', onError);
    request.once('aborted', onAborted);
  });
}

// Recovery follows preset-speech-request.ts @ 7481f167: one stable URL/body/ID,
// complete JSON object + nonempty audio, bounded attempts, abortable body/backoff.
// Direct-specific limits, legacy budget and downstream close evidence stay here.
class PresetGatewayError extends Error {
  constructor(code, stage, retryable = true, transportCode) {
    super(code);
    this.code = code;
    this.stage = stage;
    this.retryable = retryable;
    this.transportCode = transportCode;
  }
}

const TRANSPORT_CODES = new Set([
  'ECONNRESET', 'ECONNREFUSED', 'ENOTFOUND', 'EAI_AGAIN', 'ETIMEDOUT',
  'UND_ERR_CONNECT_TIMEOUT', 'UND_ERR_HEADERS_TIMEOUT', 'UND_ERR_BODY_TIMEOUT',
  'UND_ERR_SOCKET',
]);
function transportCode(error) {
  for (let depth = 0; depth < 4 && error && typeof error === 'object'; depth++) {
    if (TRANSPORT_CODES.has(error.code)) return error.code;
    error = error.cause;
  }
}

function normalizedRequestId(value) {
  const supplied = typeof value === 'string' ? value.trim() : '';
  // The stable proxy accepts at most 80 characters; preserve correlation there.
  return /^[A-Za-z0-9][A-Za-z0-9_-]{7,79}$/.test(supplied) ? supplied : randomUUID();
}

async function withinAbort(operation, signal) {
  signal.throwIfAborted();
  let onAbort;
  try {
    return await Promise.race([
      operation,
      new Promise((_, reject) => {
        onAbort = () => reject(signal.reason);
        signal.addEventListener('abort', onAbort, { once: true });
      }),
    ]);
  } finally {
    if (onAbort) signal.removeEventListener('abort', onAbort);
  }
}

async function readLimitedText(response, signal) {
  const chunks = [];
  let total = 0;
  if (!response.body) return '';
  const reader = response.body.getReader();
  let complete = false;
  try {
    for (;;) {
      const { value, done } = await withinAbort(reader.read(), signal);
      if (done) { complete = true; break; }
      total += value.length;
      if (total > MAX_UPSTREAM_RESPONSE_BYTES) {
        throw new PresetGatewayError('TTS_UPSTREAM_RESPONSE_TOO_LARGE', 'upstream_body', false);
      }
      chunks.push(value);
    }
    return Buffer.concat(chunks).toString('utf8');
  } finally {
    if (!complete) void reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

function parseCompleteJsonDocument(body) {
  // Parse the whole response: extra records must never be silently discarded.
  // stream:false above asks the upstream to assemble the complete audio itself.
  return JSON.parse(body);
}

const TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);
const SAFE_ERROR_HEADERS = [
  'retry-after', 'x-voice-error-code', 'x-tts-error-code', 'x-voice-retryable',
  'x-clone-quota-limit-seconds', 'x-clone-quota-used-seconds',
  'x-clone-quota-remaining-seconds', 'x-clone-quota-reset-at', 'x-clone-quota-mode',
];
function explicitBusinessDenial(response, body) {
  const codes = [response.headers.get('x-voice-error-code'), response.headers.get('x-tts-error-code')];
  let payload;
  let nonRetryable = false;
  try { payload = JSON.parse(body); } catch { /* A non-JSON error is not a denial code. */ }
  if (payload && typeof payload === 'object' && !Array.isArray(payload)) {
    codes.push(payload.code, payload.error_code, payload.error?.code, payload.detail?.code);
    nonRetryable = payload.retryable === false || payload.error?.retryable === false;
  }
  const code = codes.find(code => typeof code === 'string' &&
    /^[A-Za-z][A-Za-z0-9_]{1,95}$/.test(code) &&
    /QUOTA|ENTITLEMENT|SUBSCRIPTION|PRO_REQUIRED/i.test(code));
  return { code: code || 'TTS_UPSTREAM_NONRETRYABLE', denied: Boolean(code) || nonRetryable ||
    (response.status === 429 && response.headers.has('x-clone-quota-limit-seconds')) ||
    response.headers.get('x-voice-retryable')?.trim().toLowerCase() === 'false' };
}

function validatedAudio(body) {
  let result;
  try { result = parseCompleteJsonDocument(body); }
  catch { throw new PresetGatewayError('TTS_UPSTREAM_INVALID_JSON', 'response_validation'); }
  if (!result || typeof result !== 'object' || Array.isArray(result)) {
    throw new PresetGatewayError('TTS_UPSTREAM_INVALID_PAYLOAD', 'response_validation');
  }
  if (typeof result.audio !== 'string' || !result.audio.trim()) {
    throw new PresetGatewayError('TTS_UPSTREAM_EMPTY_AUDIO', 'response_validation');
  }
  // Timing is client presentation metadata; it must never cause another GPU call.
  return result;
}

async function requestPresetUpstream({ url, body, requestId, signal, attemptTimeoutMs,
  retryDelaysMs, fetchImpl, onEvent }) {
  const delays = retryDelaysMs.slice(0, 2);
  for (let attempt = 1; ; attempt++) {
    signal.throwIfAborted();
    const current = new AbortController();
    const joined = AbortSignal.any([signal, current.signal]);
    let stage = 'upstream_headers';
    let failure;
    let response;
    let retryDelayMs = delays[attempt - 1];
    const timeout = setTimeout(() => current.abort(
      new PresetGatewayError('TTS_ATTEMPT_TIMEOUT', stage)
    ), attemptTimeoutMs);
    timeout.unref();
    onEvent('attempt_start', { attempt, stage, attemptTimeoutMs });
    try {
      const pending = Promise.resolve().then(() => {
        joined.throwIfAborted();
        return fetchImpl(url, {
          method: 'POST', redirect: 'error', body, signal: joined,
          headers: { accept: 'application/json', 'content-type': 'application/json',
            'x-request-id': requestId, 'x-castreader-tts-attempt': String(attempt) },
        });
      });
      // A custom transport can resolve after our abort race already returned.
      void pending.then(late => {
        if (joined.aborted && late.body && !late.body.locked) void late.body.cancel().catch(() => {});
      }).catch(() => {});
      response = await withinAbort(pending, joined);
      stage = 'upstream_body';
      onEvent('upstream_headers', { attempt, stage, status: response.status });
      const text = await readLimitedText(response, joined);
      joined.throwIfAborted();
      stage = 'response_validation';
      onEvent('upstream_body', { attempt, stage, status: response.status, bodyBytes: Buffer.byteLength(text) });
      if (response.ok) {
        try { return { response, result: validatedAudio(text) }; }
        catch (error) {
          // Some upstreams encode an explicit refusal inside HTTP 200. Preserve
          // its safe code without retrying; complete audio still always wins.
          const refusal = explicitBusinessDenial(response, text);
          if (refusal.denied) throw new PresetGatewayError(refusal.code, stage, false);
          throw error;
        }
      }
      const { denied } = explicitBusinessDenial(response, text);
      if (!TRANSIENT_STATUSES.has(response.status) || denied || attempt > delays.length) {
        return { response, text, denied };
      }
      failure = new PresetGatewayError('TTS_UPSTREAM_HTTP', stage);
      const retryAfter = Number(response.headers.get('retry-after'));
      if (Number.isFinite(retryAfter) && retryAfter > 0) retryDelayMs = Math.min(retryAfter * 1000, 8000);
    } catch (error) {
      failure = joined.aborted && joined.reason instanceof PresetGatewayError
        ? joined.reason : error instanceof PresetGatewayError ? error
          : new PresetGatewayError(
            error?.name === 'AbortError' || error?.name === 'TimeoutError'
              ? 'TTS_UPSTREAM_ABORTED' : 'TTS_UPSTREAM_TRANSPORT', stage, true, transportCode(error));
    } finally {
      clearTimeout(timeout);
      if (failure && !current.signal.aborted) current.abort(failure);
      if (failure && response?.body && !response.body.locked) void response.body.cancel().catch(() => {});
    }
    onEvent('attempt_failed', { attempt, stage: failure.stage, code: failure.code, transportCode: failure.transportCode });
    signal.throwIfAborted();
    if (!failure.retryable || attempt > delays.length) throw failure;
    onEvent('retry_scheduled', { attempt, stage: 'backoff', code: failure.code, retryDelayMs });
    try { await delay(retryDelayMs, undefined, { signal }); }
    catch { signal.throwIfAborted(); throw failure; }
  }
}

export function createGateway({
  upstreamUrl = DEFAULT_UPSTREAM,
  resolveUpstream = () => upstreamUrl,
  maxInFlight = DEFAULT_MAX_IN_FLIGHT,
  fetchImpl = fetch,
  log = console,
  upstreamTimeoutMs = UPSTREAM_TIMEOUT_MS,
  requestPolicies = {},
  retryDelaysMs = [500, 1500],
} = {}) {
  let inFlight = 0;
  const policies = {
    legacy: { budgetMs: upstreamTimeoutMs, attemptTimeoutMs: upstreamTimeoutMs, ...requestPolicies.legacy },
    'extension-v1': { ...REQUEST_POLICIES['extension-v1'], ...requestPolicies['extension-v1'] },
  };

  return http.createServer(async (request, response) => {
    const requestId = normalizedRequestId(request.headers['x-request-id']);
    const policyName = request.headers['x-castreader-tts-policy'] === 'extension-v1' ? 'extension-v1' : 'legacy';
    const policy = policies[policyName];
    const pathname = (request.url || '').split('?', 1)[0];
    let attempts = 0;
    const requestKey = createHash('sha256')
      .update(String(requestId))
      .digest('hex')
      .slice(0, 20);
    const platform = request.headers['x-castreader-platform'];
    const clientPlatform = [
      'ios',
      'android',
      'web',
      'extension',
      'ops',
    ].includes(platform)
      ? platform
      : 'unknown';
    const version = String(request.headers['x-castreader-version'] || '');
    const clientVersion =
      /^\d+(?:\.\d+){0,3}(?:\(\d+\))?$/.test(version) && version.length <= 32
        ? version
        : 'unknown';
    response.setHeader('x-request-id', requestId);
    response.setHeader('x-castreader-tts-contract', GATEWAY_CONTRACT);
    response.setHeader('x-castreader-tts-policy', policyName);
    response.setHeader('x-castreader-tts-attempts', '0');

    if (request.method === 'GET' && pathname === '/health') {
      jsonResponse(response, 200, { ok: true, in_flight: inFlight });
      return;
    }
    if (request.method === 'HEAD' && pathname === '/api/captioned_speech_partly') {
      // Capability probe only: this does not contact or assert health of a model.
      response.writeHead(200, { 'cache-control': 'no-store', 'x-castreader-gateway': 'direct-us' });
      response.end();
      return;
    }
    if (
      request.method !== 'POST' ||
      pathname !== '/api/captioned_speech_partly'
    ) {
      jsonResponse(response, 404, { detail: 'Not found' });
      return;
    }
    if (inFlight >= maxInFlight) {
      jsonResponse(
        response,
        503,
        { detail: 'TTS gateway is busy', code: 'TTS_GATEWAY_BUSY' },
        {
          'retry-after': '2',
          'x-tts-error-code': 'TTS_GATEWAY_BUSY',
          'x-voice-retryable': 'true',
        }
      );
      return;
    }

    const startedAt = Date.now();
    let submittedBytes = 0;
    let stage = 'request_body';
    let abortSource = null;
    let abortStage = null;
    let downstreamDisconnected = false;
    const controller = new AbortController();
    let timeout;
    const abort = (source) => {
      if (controller.signal.aborted) return;
      abortSource = source;
      abortStage = stage;
      controller.abort(new PresetGatewayError(
        source === 'downstream_closed' ? 'TTS_DOWNSTREAM_CLOSED'
          : policyName === 'legacy' ? 'TTS_UPSTREAM_TIMEOUT' : 'TTS_TOTAL_BUDGET_EXCEEDED',
        stage, false
      ));
    };
    const disconnected = () =>
      downstreamDisconnected || response.destroyed || request.aborted;
    const abortIfDownstreamClosed = () => {
      if (response.writableEnded) return;
      downstreamDisconnected = true;
      abort('downstream_closed');
    };
    response.once('close', abortIfDownstreamClosed);
    request.once('aborted', abortIfDownstreamClosed);
    const safeLog = (level, event, data) => {
      try {
        log[level]?.(event, data);
      } catch {
        /* Diagnostics cannot affect audio. */
      }
    };
    inFlight += 1;
    try {
      let rawBody;
      try {
        rawBody = await readRequestBody(request);
        submittedBytes = Buffer.byteLength(rawBody);
      } catch (error) {
        if (disconnected()) throw error;
        jsonResponse(response, error.status || 400, {
          detail:
            error.status === 413
              ? 'Request body exceeds 64 KiB'
              : 'Invalid request body',
        }, error.status === 413 ? { connection: 'close' } : {});
        return;
      }

      stage = 'request_validation';
      let decoded;
      try {
        decoded = JSON.parse(rawBody);
      } catch {
        jsonResponse(response, 400, { detail: 'Invalid JSON body' });
        return;
      }
      const prepared = preparePayload(decoded);
      if (prepared.error) {
        jsonResponse(
          response,
          prepared.error.status,
          prepared.error.body || { detail: prepared.error.detail }
        );
        return;
      }

      if (disconnected()) abortIfDownstreamClosed();
      controller.signal.throwIfAborted();
      if (!prepared.payload.input.trim() || isPunctuationOnly(prepared.payload.input)) {
        // Match the account gateway for citation-only / punctuation-only pieces.
        // Preserve source continuation fields while avoiding anonymous GPU work.
        const result = {
          audio: PUNCTUATION_ONLY_SILENCE_MP3,
          audio_format: 'audio/mpeg',
          timestamps: [],
        };
        if (prepared.voiceCode) result.voice_code = prepared.voiceCode;
        if (prepared.processedText && prepared.unprocessedText) {
          result.processed_text = prepared.processedText;
          result.unprocessed_text = prepared.unprocessedText;
        }
        stage = 'response';
        jsonResponse(response, 200, result, {
          'x-castreader-tts-noop': 'punctuation-only',
        });
        return;
      }
      stage = 'upstream_headers';
      timeout = setTimeout(() => abort('upstream_timeout'), policy.budgetMs);
      timeout.unref();
      const { response: upstream, result, text: upstreamBody, denied } = await requestPresetUpstream({
        url: resolveUpstream(),
        // Serialize once for all attempts. Never change voice, route or request ID.
        body: JSON.stringify(prepared.payload),
        requestId, signal: controller.signal, attemptTimeoutMs: policy.attemptTimeoutMs,
        retryDelaysMs, fetchImpl,
        onEvent: (event, data) => {
          stage = data.stage;
          attempts = data.attempt;
          response.setHeader('x-castreader-tts-attempts', String(attempts));
          safeLog('info', 'tts_gateway_recovery', {
            event, requestKey, policy: policyName, ...data, elapsedMs: Date.now() - startedAt,
          });
        },
      });
      clearTimeout(timeout);

      stage = 'response_validation';
      if (!upstream.ok) {
        const errorHeaders = {};
        for (const name of SAFE_ERROR_HEADERS) {
          const value = upstream.headers.get(name);
          if (value) errorHeaders[name] = value;
        }
        if (!errorHeaders['x-tts-error-code']) errorHeaders['x-tts-error-code'] = 'TTS_UPSTREAM_HTTP';
        if (denied) errorHeaders['x-voice-retryable'] = 'false';
        response.writeHead(upstream.status, {
          'cache-control': 'no-store',
          'content-type':
            upstream.headers.get('content-type') || 'application/json',
          'x-castreader-gateway': 'direct-us',
          'x-request-id': requestId,
          ...errorHeaders,
        });
        response.end(upstreamBody);
        return;
      }

      const timestamps = playbackTimestamps(normalizeTimestampAliases(result.timestamps));
      const degradedTiming = timestamps.length === 0 ||
        (prepared.payload.return_timestamps === true && prepared.payload.language === 'en' &&
          !timestampsCoverEnglishInput(prepared.payload.input, timestamps));
      result.timestamps = degradedTiming ? [] : timestamps;
      response.setHeader('x-castreader-tts-timing', degradedTiming ? 'segment' : 'word');
      if (prepared.voiceCode) result.voice_code = prepared.voiceCode;
      if (prepared.processedText && prepared.unprocessedText) {
        result.processed_text = prepared.processedText;
        result.unprocessed_text = prepared.unprocessedText;
      }
      stage = 'response';
      jsonResponse(response, 200, result);
    } catch (error) {
      // A closed downstream connection is an observation, not evidence of a
      // user action. Only our own timer establishes an upstream timeout.
      const isTimeout = abortSource === 'upstream_timeout' || error?.code === 'TTS_ATTEMPT_TIMEOUT';
      const closed = disconnected();
      const code =
        closed && !isTimeout
          ? 'TTS_DOWNSTREAM_CLOSED'
          : error instanceof PresetGatewayError
            ? error.code
            : 'TTS_UPSTREAM_UNAVAILABLE';
      if (!closed && !response.headersSent) {
        jsonResponse(response, isTimeout ? 504 : 502, {
          detail: isTimeout
            ? 'TTS upstream timeout'
            : 'TTS upstream unavailable',
          code,
          request_id: requestId,
        }, { 'x-tts-error-code': code,
          ...(error instanceof PresetGatewayError && !error.retryable ? { 'x-voice-retryable': 'false' } : {}) });
      } else if (!closed && !response.writableEnded) {
        response.destroy();
      }
      safeLog('error', 'tts_gateway_error', {
        requestKey,
        code,
        stage,
        abortSource,
        abortStage,
        downstreamDisconnected: closed,
        transportCode: error instanceof PresetGatewayError ? error.transportCode : undefined,
      });
    } finally {
      clearTimeout(timeout);
      response.off('close', abortIfDownstreamClosed);
      request.off('aborted', abortIfDownstreamClosed);
      inFlight -= 1;
      safeLog('info', 'tts_gateway_request', {
        requestKey,
        method: request.method,
        path: pathname,
        // null means no HTTP response was sent; never invent a 504 (or 200).
        status: response.headersSent ? response.statusCode : null,
        stage,
        abortSource,
        abortStage,
        downstreamDisconnected: disconnected(),
        requestBytes: submittedBytes,
        elapsedMs: Date.now() - startedAt,
        clientPlatform,
        clientVersion,
        policy: policyName,
        attempts,
      });
    }
  });
}

export function gatewayUpstreamUrl(environment = process.env) {
  const configured = environment.TTS_UPSTREAM_URL || DEFAULT_UPSTREAM;
  if (configured !== DEFAULT_UPSTREAM && configured !== LEGACY_UPSTREAM) {
    throw new Error('TTS gateway requires the approved US stable upstream');
  }
  // Existing service units contain the retired worker URL. It is a migration
  // alias only: requests always use the stable proxy, including after a restart.
  return DEFAULT_UPSTREAM;
}

export function startGateway() {
  const host = process.env.TTS_GATEWAY_HOST || DEFAULT_HOST;
  const port = Number(process.env.TTS_GATEWAY_PORT || DEFAULT_PORT);
  const upstreamUrl = gatewayUpstreamUrl();
  const maxInFlight = Number(
    process.env.TTS_GATEWAY_MAX_IN_FLIGHT || DEFAULT_MAX_IN_FLIGHT
  );
  const follower = createOriginFollower({fallback:upstreamUrl});
  void follower.refresh();
  const timer = setInterval(() => { void follower.refresh(); }, 300_000);
  timer.unref();
  const server = createGateway({ upstreamUrl, maxInFlight, resolveUpstream:follower.current });
  server.on('close',()=>clearInterval(timer));
  server.headersTimeout = 10_000;
  server.requestTimeout = 125_000;
  server.keepAliveTimeout = 5_000;
  server.listen(port, host, () => {
    console.info('tts_gateway_started', {
      host,
      port,
      upstreamUrl,
      maxInFlight,
    });
  });
  return server;
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  startGateway();
}
