#!/usr/bin/env node

/**
 * Anonymous live-route smoke test for the Kindle storefront contract.
 *
 * This deliberately does not use cookies or credentials. It proves that every
 * selectable entry has a real TLS endpoint and that Amazon keeps logged-out
 * library navigation inside the selected marketplace. It cannot prove that a
 * particular account owns books in that marketplace; that remains a regional
 * account acceptance test.
 */

import { readFile } from 'node:fs/promises'
import { request as httpsRequest } from 'node:https'

const contractURL = new URL('./kindle-storefronts-v1.json', import.meta.url)
const contract = JSON.parse(await readFile(contractURL, 'utf8'))
const selectable = contract.storefronts.filter(storefront => storefront.entryEnabled)

const failures = []
const observations = []
const dohCache = new Map()

function normalizedHost(raw) {
  return String(raw || '').toLowerCase().replace(/\.$/, '')
}

async function resolveAWithDoH(host) {
  if (dohCache.has(host)) return dohCache.get(host)
  const endpoint = new URL('https://cloudflare-dns.com/dns-query')
  endpoint.searchParams.set('name', host)
  endpoint.searchParams.set('type', 'A')
  const response = await fetch(endpoint, {
    signal: AbortSignal.timeout(10_000),
    headers: { accept: 'application/dns-json' },
  })
  if (!response.ok) throw new Error(`DoH HTTP ${response.status}`)
  const payload = await response.json()
  const address = payload.Answer
    ?.filter(answer => answer.type === 1)
    .map(answer => answer.data)
    .find(value => /^\d{1,3}(?:\.\d{1,3}){3}$/.test(value))
  if (!address) throw new Error(`DoH returned no IPv4 address for ${host}`)
  dohCache.set(host, address)
  return address
}

function requestAtAddress(input, address) {
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
        'user-agent': 'CastReader-Kindle-Storefront-Preflight/1.0',
        accept: 'text/html,application/xhtml+xml',
      },
      lookup: (_hostname, options, callback) => {
        if (options?.all) {
          callback(null, [{ address, family: 4 }])
        } else {
          callback(null, address, 4)
        }
      },
    }, response => {
      response.resume()
      resolve({
        status: response.statusCode || 0,
        location: response.headers.location || null,
      })
    })
    request.setTimeout(15_000, () => request.destroy(new Error('request timeout')))
    request.once('error', reject)
    request.end()
  })
}

async function requestManual(input) {
  try {
    const response = await fetch(input, {
      redirect: 'manual',
      signal: AbortSignal.timeout(15_000),
      headers: {
        'user-agent': 'CastReader-Kindle-Storefront-Preflight/1.0',
        accept: 'text/html,application/xhtml+xml',
      },
    })
    return {
      status: response.status,
      location: response.headers.get('location'),
      transport: 'system-dns',
    }
  } catch (systemError) {
    // Some mainland networks poison the Japan hostname to an unrelated IP.
    // A DNS-over-HTTPS retry preserves SNI/certificate validation and lets the
    // verifier distinguish route failure from local resolver contamination.
    try {
      const address = await resolveAWithDoH(new URL(input).hostname)
      const response = await requestAtAddress(input, address)
      return {
        ...response,
        transport: `doh:${address}`,
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

async function inspect(storefront, host, path, purpose) {
  const input = `https://${host}${path}`
  try {
    const response = await requestManual(input)
    const location = response.location
    const destination = location ? new URL(location, input) : null
    const allowedHosts = new Set([storefront.canonicalHost, ...storefront.aliasHosts])
    const destinationHost = normalizedHost(destination?.hostname)
    const statusOK = response.status >= 200 && response.status < 400
    const routeOK = !destination || (
      destination.protocol === 'https:' &&
      allowedHosts.has(destinationHost)
    )

    observations.push({
      id: storefront.id,
      purpose,
      host,
      status: response.status,
      destination: destination?.hostname || '-',
      transport: response.transport,
      ok: statusOK && routeOK,
    })

    if (!statusOK) {
      failures.push(`${storefront.id} ${purpose}: HTTP ${response.status} at ${input}`)
    } else if (!routeOK) {
      failures.push(
        `${storefront.id} ${purpose}: escaped marketplace to ${destination?.href || 'unknown'}`
      )
    }
  } catch (error) {
    observations.push({
      id: storefront.id,
      purpose,
      host,
      status: 'ERR',
      destination: '-',
      transport: '-',
      ok: false,
    })
    failures.push(`${storefront.id} ${purpose}: ${error?.message || error}`)
  }
}

for (const storefront of selectable) {
  await inspect(storefront, storefront.canonicalHost, '/landing', 'landing')
  await inspect(
    storefront,
    storefront.canonicalHost,
    contract.paths.library,
    'logged-out-library'
  )
  for (const alias of storefront.aliasHosts) {
    await inspect(storefront, alias, '/landing', 'legacy-alias')
  }
}

console.table(observations)

if (failures.length) {
  console.error(`FAIL Kindle live routes (${failures.length})`)
  for (const failure of failures) console.error(`- ${failure}`)
  process.exitCode = 1
} else {
  console.log(
    `PASS Kindle live routes: ${selectable.length} entry storefronts, ` +
    `${observations.length} anonymous route checks, no cross-marketplace redirect`
  )
}
