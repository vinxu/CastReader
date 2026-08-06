#!/usr/bin/env node

/**
 * Anonymous live-route smoke test for the Kindle storefront contract.
 *
 * This deliberately sends no Cookie header and uses a synthetic ASIN. It proves
 * DNS/TLS reachability and main-frame redirect semantics only; it cannot prove
 * that a real regional account can scan a shelf or open an owned book.
 *
 * Important: fresh navigation is always built from canonicalHost. Alias routes
 * are migration probes only. Several localized read.amazon.* aliases discard
 * /kindle-library while redirecting to their localized canonical root; that is
 * reported as ALIAS_RISK and must not be misreported as a canonical outage.
 */

import { readFile } from 'node:fs/promises'
import { request as httpsRequest } from 'node:https'
import {
  evaluateRoute,
  freshLibraryURL,
  freshReaderURL,
  isRedirectStatus,
  normalizeHost,
  safeRouteLabel,
} from './kindle-live-route-policy.mjs'

const contractURL = new URL('./kindle-storefronts-v1.json', import.meta.url)
const contract = JSON.parse(await readFile(contractURL, 'utf8'))
const selectable = contract.storefronts.filter(storefront => storefront.entryEnabled)
const syntheticASIN = 'B012345678'
const redirectLimit = 10
const concurrency = 4
const networkAttemptLimit = 2
const maxHTMLBytes = 1_500_000
// Amazon may route `/kindle-library` differently for bot/custom UAs. The
// profiles below cover Android parity, visible iPhone Safari login, and the
// exact desktop UA currently used by the iOS Kindle reader.
const userAgentProfiles = {
  android: (
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36'
  ),
  'ios-safari': (
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) ' +
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1'
  ),
  'ios-desktop': (
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
  ),
}
const profileArgument = process.argv
  .find(argument => argument.startsWith('--profile='))
  ?.slice('--profile='.length) ?? 'all'
const selectedProfileIDs = profileArgument === 'all'
  ? Object.keys(userAgentProfiles)
  : profileArgument.split(',').filter(Boolean)
for (const profileID of selectedProfileIDs) {
  if (!userAgentProfiles[profileID]) {
    throw new Error(
      'unknown profile ' + profileID + '; expected all or ' +
      Object.keys(userAgentProfiles).join(',')
    )
  }
}

const failures = []
const warnings = []
const observations = []
const dohCache = new Map()

const dohProviders = [
  ['cloudflare', 'https://cloudflare-dns.com/dns-query'],
  ['google', 'https://dns.google/resolve'],
  ['alidns', 'https://dns.alidns.com/resolve'],
  ['dnspod', 'https://doh.pub/dns-query'],
]

async function queryAWithDoH(provider, endpointString, host) {
  const endpoint = new URL(endpointString)
  endpoint.searchParams.set('name', host)
  endpoint.searchParams.set('type', 'A')
  const response = await fetch(endpoint, {
    signal: AbortSignal.timeout(10_000),
    headers: { accept: 'application/dns-json' },
  })
  if (!response.ok) throw new Error(`${provider}: HTTP ${response.status}`)
  const payload = await response.json()
  const addresses = payload.Answer
    ?.filter(answer => Number(answer.type) === 1)
    .map(answer => String(answer.data || ''))
    .filter(value => /^\d{1,3}(?:\.\d{1,3}){3}$/.test(value)) ?? []
  if (!addresses.length) throw new Error(`${provider}: no IPv4 answer`)
  return { provider, addresses }
}

async function resolveAWithDoH(host) {
  if (dohCache.has(host)) return dohCache.get(host)
  const pending = (async () => {
    const results = await Promise.allSettled(
      dohProviders.map(([provider, endpoint]) =>
        queryAWithDoH(provider, endpoint, host)
      ),
    )
    const providersByAddress = new Map()
    for (const result of results) {
      if (result.status !== 'fulfilled') continue
      for (const address of result.value.addresses) {
        const providers = providersByAddress.get(address) ?? []
        providers.push(result.value.provider)
        providersByAddress.set(address, providers)
      }
    }
    const candidates = [...providersByAddress].map(([address, providers]) => ({
      address,
      providers,
    }))
    if (!candidates.length) {
      const reasons = results.map((result, index) =>
        result.status === 'rejected'
          ? `${dohProviders[index][0]}:${result.reason?.message || result.reason}`
          : `${dohProviders[index][0]}:no-answer`
      )
      throw new Error(`all DoH providers failed (${reasons.join(', ')})`)
    }
    return candidates
  })()
  dohCache.set(host, pending)
  try {
    return await pending
  } catch (error) {
    dohCache.delete(host)
    throw error
  }
}

function requestAtAddress(input, address, userAgent) {
  const url = new URL(input)
  return new Promise((resolve, reject) => {
    const request = httpsRequest({
      protocol: 'https:',
      hostname: url.hostname,
      port: 443,
      path: `${url.pathname}${url.search}`,
      method: 'GET',
      servername: url.hostname,
      headers: {
        host: url.hostname,
        'user-agent': userAgent,
        accept: 'text/html,application/xhtml+xml',
        'accept-language': 'en-US,en;q=0.8',
        'accept-encoding': 'identity',
        // No Cookie header: this verifier must never consume account state.
      },
      lookup: (_hostname, options, callback) => {
        if (options?.all) {
          callback(null, [{ address, family: 4 }])
        } else {
          callback(null, address, 4)
        }
      },
    }, response => {
      const chunks = []
      let capturedBytes = 0
      response.on('data', chunk => {
        if (capturedBytes >= maxHTMLBytes) return
        const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
        const remaining = maxHTMLBytes - capturedBytes
        chunks.push(buffer.subarray(0, remaining))
        capturedBytes += Math.min(buffer.length, remaining)
      })
      response.on('end', () => {
        resolve({
          status: response.statusCode || 0,
          location: response.headers.location || null,
          body: Buffer.concat(chunks).toString('utf8'),
        })
      })
    })
    request.setTimeout(15_000, () => request.destroy(new Error('request timeout')))
    request.once('error', reject)
    request.end()
  })
}

async function requestManual(input, userAgent) {
  try {
    const response = await fetch(input, {
      redirect: 'manual',
      signal: AbortSignal.timeout(15_000),
      headers: {
        'user-agent': userAgent,
        accept: 'text/html,application/xhtml+xml',
        'accept-language': 'en-US,en;q=0.8',
        'accept-encoding': 'identity',
        // fetch has no cookie jar and no Cookie header is provided.
      },
    })
    const body = (await response.text()).slice(0, maxHTMLBytes)
    return {
      status: response.status,
      location: response.headers.get('location'),
      transport: 'system-dns',
      body,
    }
  } catch (systemError) {
    // Some mainland networks poison the Japan hostname to an unrelated IP.
    // A DNS-over-HTTPS retry preserves SNI/certificate validation and lets the
    // verifier distinguish route failure from local resolver contamination.
    try {
      const candidates = await resolveAWithDoH(new URL(input).hostname)
      const attempts = candidates.map(async candidate => ({
        candidate,
        response: await requestAtAddress(input, candidate.address, userAgent),
      }))
      let candidate
      let response
      try {
        ;({ candidate, response } = await Promise.any(attempts))
      } catch {
        const providers = [...new Set(candidates.flatMap(item => item.providers))]
        throw new Error(
          `DoH resolved via ${providers.join('+')} but every TLS/SNI address was unreachable`
        )
      }
      return {
        ...response,
        transport: `doh:${candidate.providers.join('+')}`,
        systemError: systemError?.message || String(systemError),
      }
    } catch (fallbackError) {
      throw new Error(
        `system DNS: ${systemError?.cause?.message || systemError?.message || systemError}; ` +
        `DoH retry: ${fallbackError?.cause?.message || fallbackError?.message || fallbackError}`
      )
    }
  }
}

async function requestRedirectChain(input, userAgent) {
  const chain = []
  const visited = new Set()
  let current = input
  let redirectLimitReached = false

  for (let index = 0; index <= redirectLimit; index += 1) {
    if (visited.has(current)) {
      return { chain, redirectLimitReached: true, loopDetected: true }
    }
    visited.add(current)
    const response = await requestManual(current, userAgent)
    const destination = response.location
      ? new URL(response.location, current).href
      : null
    chain.push({
      url: current,
      status: response.status,
      location: destination,
      transport: response.transport,
      body: response.body || '',
    })
    if (!isRedirectStatus(response.status) || !destination) break
    if (index === redirectLimit) {
      redirectLimitReached = true
      break
    }
    current = destination
  }
  return { chain, redirectLimitReached, loopDetected: false }
}

function decodeHTMLAttribute(value) {
  return String(value || '')
    .replace(/\\\//g, '/')
    .replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"')
    .replace(/&#x27;|&#39;|&apos;/gi, "'")
    .replace(/&#x2f;/gi, '/')
}

function authenticationLinksFromHTML(html, baseURL) {
  if (!html) return []
  const candidates = []
  for (const match of html.matchAll(/(?:href|action)\s*=\s*["']([^"']+)["']/gi)) {
    candidates.push(match[1])
  }
  for (const match of html.matchAll(/https?:\\?\/\\?\/[^"'\s<>]+\/ap\/signin[^"'\s<>]*/gi)) {
    candidates.push(match[0])
  }
  const unique = new Set()
  for (const candidate of candidates) {
    try {
      const url = new URL(decodeHTMLAttribute(candidate), baseURL)
      if (url.protocol === 'https:' && url.pathname.toLowerCase().includes('/ap/signin')) {
        unique.add(url.href)
      }
    } catch {
      // Ignore malformed markup; it is not route evidence.
    }
  }
  return [...unique].slice(0, 12)
}

function aliasReaderURL(storefront, alias) {
  const url = new URL(`https://${alias}${contract.paths.reader}`)
  url.searchParams.set('asin', syntheticASIN)
  url.searchParams.set('ref_', contract.readerRef)
  return url.href
}

function jobsForStorefront(storefront, profile) {
  const freshLibrary = freshLibraryURL(storefront, contract.paths.library)
  const freshReader = freshReaderURL(
    storefront,
    contract.paths.reader,
    syntheticASIN,
    contract.readerRef,
  )

  // This is the executable proof that new app navigation never starts from an
  // alias: both fresh URLs are built exclusively from canonicalHost.
  if (normalizeHost(new URL(freshLibrary).hostname) !== storefront.canonicalHost) {
    throw new Error(`${storefront.id}: fresh library navigation is not canonical`)
  }
  if (normalizeHost(new URL(freshReader).hostname) !== storefront.canonicalHost) {
    throw new Error(`${storefront.id}: fresh reader navigation is not canonical`)
  }

  const jobs = [
    {
      storefront,
      profile,
      purpose: 'canonical-landing',
      input: `https://${storefront.canonicalHost}/landing`,
    },
    { storefront, profile, purpose: 'canonical-library', input: freshLibrary },
    { storefront, profile, purpose: 'canonical-reader', input: freshReader },
  ]
  for (const alias of storefront.aliasHosts ?? []) {
    jobs.push({
      storefront,
      profile,
      purpose: 'alias-library',
      input: `https://${alias}${contract.paths.library}`,
    })
    jobs.push({
      storefront,
      profile,
      purpose: 'alias-reader',
      input: aliasReaderURL(storefront, alias),
    })
  }
  return jobs
}

async function inspect(job) {
  const entry = safeRouteLabel(job.input)
  let lastNetworkError = null
  for (let attempt = 1; attempt <= networkAttemptLimit; attempt += 1) {
    try {
      const redirect = await requestRedirectChain(
        job.input,
        userAgentProfiles[job.profile],
      )
      const terminal = redirect.chain.at(-1)
      const relatedURLs = authenticationLinksFromHTML(
        terminal?.body,
        terminal?.url || job.input,
      )
      const result = evaluateRoute({
        storefront: job.storefront,
        purpose: job.purpose,
        chain: redirect.chain,
        libraryPath: contract.paths.library,
        asin: syntheticASIN,
        readerRef: contract.readerRef,
        relatedURLs,
        redirectLimitReached: redirect.redirectLimitReached || redirect.loopDetected,
      })
      const routeWarnings = result.warnings.map(code => `${job.storefront.id} ${job.purpose}: ${code}`)
      const routeFailures = result.failures.map(code => `${job.storefront.id} ${job.purpose}: ${code}`)
      warnings.push(...routeWarnings.map(value => job.profile + ' ' + value))
      failures.push(...routeFailures.map(value => job.profile + ' ' + value))
      observations.push({
        id: job.storefront.id,
        profile: job.profile,
        purpose: job.purpose,
        entry,
        hops: redirect.chain.length,
        terminal: safeRouteLabel(terminal?.url),
        status: terminal?.status ?? 'ERR',
        semantic: result.failures.join(',') || result.warnings.join(',') || 'preserved',
        result: result.ok ? (result.warnings.length ? 'ALIAS_RISK' : 'PASS') : 'FAIL',
      })
      return
    } catch (error) {
      lastNetworkError = error
      if (attempt < networkAttemptLimit) {
        await new Promise(resolve => setTimeout(resolve, 500 * attempt))
      }
    }
  }

  observations.push({
    id: job.storefront.id,
    profile: job.profile,
    purpose: job.purpose,
    entry,
    hops: 0,
    terminal: '-',
    status: 'ERR',
    semantic: 'network_error',
    result: 'FAIL',
  })
  failures.push(
    job.profile + ' ' +
    `${job.storefront.id} ${job.purpose}: after ${networkAttemptLimit} attempts: ` +
    `${lastNetworkError?.message || lastNetworkError}`
  )
}

async function runStorefrontsWithConcurrency(storefrontJobGroups, limit) {
  let cursor = 0
  async function worker() {
    while (cursor < storefrontJobGroups.length) {
      const index = cursor
      cursor += 1
      // Keep one storefront's probes sequential. Amazon can throttle several
      // simultaneous anonymous requests to the same regional edge, while
      // parallelism across independent storefronts is still useful.
      for (const job of storefrontJobGroups[index]) await inspect(job)
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(limit, storefrontJobGroups.length) }, worker)
  )
}

const storefrontJobGroups = selectable.map(storefront =>
  selectedProfileIDs.flatMap(profile => jobsForStorefront(storefront, profile))
)
const jobs = storefrontJobGroups.flat()
await runStorefrontsWithConcurrency(storefrontJobGroups, concurrency)

const storefrontOrder = new Map(selectable.map((storefront, index) => [storefront.id, index]))
const purposeOrder = new Map([
  'canonical-landing',
  'canonical-library',
  'canonical-reader',
  'alias-library',
  'alias-reader',
].map((purpose, index) => [purpose, index]))
observations.sort((left, right) =>
  (storefrontOrder.get(left.id) ?? 999) - (storefrontOrder.get(right.id) ?? 999) ||
  selectedProfileIDs.indexOf(left.profile) - selectedProfileIDs.indexOf(right.profile) ||
  (purposeOrder.get(left.purpose) ?? 999) - (purposeOrder.get(right.purpose) ?? 999),
)

console.log('UA profiles: ' + selectedProfileIDs.join(', '))
console.table(observations)
console.log(
  `Fresh navigation proof: ${selectable.length} selectable storefronts use canonicalHost for ` +
  'both library and reader entry; aliases are recognition/migration probes only.'
)

if (warnings.length) {
  console.warn(`ALIAS_RISK Kindle live routes (${warnings.length})`)
  for (const warning of warnings) console.warn(`- ${warning}`)
}

if (failures.length) {
  console.error(`FAIL Kindle live routes (${failures.length})`)
  for (const failure of failures) console.error(`- ${failure}`)
  process.exitCode = 1
} else {
  console.log(
    `PASS Kindle live routes: ${selectable.length} canonical storefronts, ` +
    `${jobs.length} full-chain anonymous checks, ${warnings.length} explicit alias risks, ` +
    'no canonical path loss, cross-storefront redirect, or reader identity loss.'
  )
}
