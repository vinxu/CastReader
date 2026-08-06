/**
 * Pure policy helpers for the anonymous Kindle storefront live-route verifier.
 *
 * Keep this module free of network and credential access so redirect semantics
 * can be covered by deterministic offline tests.
 */

const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308])

export function normalizeHost(raw) {
  const value = String(raw || '')
  if (!value || value !== value.trim()) return null
  const lowered = value.toLowerCase()
  const host = lowered.endsWith('.') ? lowered.slice(0, -1) : lowered
  return host && !host.endsWith('.') ? host : null
}

export function marketplaceDomain(storefront) {
  const labels = normalizeHost(storefront?.canonicalHost)?.split('.') ?? []
  const amazonIndex = labels.indexOf('amazon')
  if (amazonIndex < 0 || amazonIndex >= labels.length - 1) {
    throw new Error(`invalid Amazon storefront host: ${storefront?.canonicalHost || '-'}`)
  }
  return labels.slice(amazonIndex).join('.')
}

export function freshLibraryURL(storefront, libraryPath) {
  return `https://${storefront.canonicalHost}${libraryPath}`
}

export function freshReaderURL(storefront, readerPath, asin, readerRef) {
  const url = new URL(`https://${storefront.canonicalHost}${readerPath}`)
  url.searchParams.set('asin', asin)
  url.searchParams.set('ref_', readerRef)
  return url.href
}

export function isRedirectStatus(status) {
  return REDIRECT_STATUSES.has(Number(status))
}

function normalizedPath(url) {
  let path = url.pathname.toLowerCase()
  while (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1)
  return path || '/'
}

function isSameOrSubdomain(host, registrableDomain) {
  return host === registrableDomain || host.endsWith(`.${registrableDomain}`)
}

function isAuthenticationURL(url, storefront) {
  const host = normalizeHost(url.hostname)
  if (!host || !isSameOrSubdomain(host, marketplaceDomain(storefront))) return false
  const path = url.pathname.toLowerCase()
  const queryNames = [...url.searchParams.keys()].map(name => name.toLowerCase())
  return path.includes('/ap/signin') ||
    path.includes('/ap/cvf') ||
    host.includes('authportal') ||
    queryNames.some(name => name.startsWith('openid.'))
}

function secureURL(rawURL) {
  let url
  try {
    url = new URL(rawURL)
  } catch {
    return null
  }
  if (
    url.protocol !== 'https:' ||
    url.username ||
    url.password ||
    (url.port && url.port !== '443')
  ) {
    return null
  }
  return url
}

function recognizedHosts(storefront) {
  return new Set(
    [storefront.canonicalHost, ...(storefront.aliasHosts ?? [])].map(normalizeHost),
  )
}

function decodedAbsoluteURL(rawValue, maxDecodes = 3) {
  let candidate = String(rawValue || '')
  for (let depth = 0; depth <= maxDecodes; depth += 1) {
    const parsed = secureURL(candidate)
    if (parsed) return parsed
    try {
      const decoded = decodeURIComponent(candidate)
      if (decoded === candidate) return null
      candidate = decoded
    } catch {
      return null
    }
  }
  return null
}

function hasSafeReturnTargets(url, storefront, depth = 0) {
  if (depth > 3) return false
  const returnItems = [...url.searchParams].filter(([name]) => {
    const normalized = name.toLowerCase()
    return normalized === 'openid.return_to' || normalized === 'return_to'
  })
  for (const [, rawTarget] of returnItems) {
    const target = decodedAbsoluteURL(rawTarget)
    if (!target) return false
    // A login callback must return to a recognized Kindle host owned by this
    // storefront, not merely to any host beneath the same Amazon marketplace.
    if (!recognizedHosts(storefront).has(normalizeHost(target.hostname))) return false
    if (!hasSafeReturnTargets(target, storefront, depth + 1)) return false
  }
  return true
}

export function routeBelongsToStorefront(rawURL, storefront) {
  const url = secureURL(rawURL)
  if (!url) return false
  const host = normalizeHost(url.hostname)
  const recognized = recognizedHosts(storefront)
  if (recognized.has(host)) return hasSafeReturnTargets(url, storefront)
  return isAuthenticationURL(url, storefront) && hasSafeReturnTargets(url, storefront)
}

function semanticURLCandidates(rawURL, maxDepth = 3) {
  const candidates = []
  const seen = new Set()
  let frontier = [String(rawURL || '')]
  for (let depth = 0; depth <= maxDepth && frontier.length; depth += 1) {
    const next = []
    for (const raw of frontier) {
      const url = decodedAbsoluteURL(raw)
      if (!url || seen.has(url.href)) continue
      seen.add(url.href)
      candidates.push(url)
      // Only login callback parameters carry navigation semantics. Traversing
      // arbitrary query values would let an unrelated `foo=` value containing
      // `/kindle-library` or ASIN/ref make a broken route look preserved.
      for (const [name, value] of url.searchParams) {
        const normalized = name.toLowerCase()
        if (
          value &&
          (normalized === 'openid.return_to' || normalized === 'return_to')
        ) {
          next.push(value)
        }
      }
    }
    frontier = next
  }
  return candidates
}

function semanticURLsAfterEntry(chain, relatedURLs = []) {
  if (!Array.isArray(chain) || chain.length === 0) return [...relatedURLs]
  if (chain.length === 1 && !chain[0].location) {
    return [chain[0].url, ...relatedURLs]
  }
  const values = []
  for (let index = 0; index < chain.length; index += 1) {
    const hop = chain[index]
    if (index > 0 && hop.url) values.push(hop.url)
    if (hop.location) values.push(hop.location)
  }
  return [...values, ...relatedURLs]
}

export function carriesLibraryPath(chain, libraryPath, relatedURLs = []) {
  const expected = libraryPath.toLowerCase().replace(/\/+$/, '') || '/'
  return semanticURLsAfterEntry(chain, relatedURLs).some(raw =>
    semanticURLCandidates(raw).some(url => {
      const path = normalizedPath(url)
      return path === expected || path.startsWith(`${expected}/`)
    }),
  )
}

export function carriesReaderIdentity(chain, asin, readerRef, relatedURLs = []) {
  const expectedASIN = String(asin).toLowerCase()
  const expectedRef = String(readerRef).toLowerCase()
  return semanticURLsAfterEntry(chain, relatedURLs).some(raw =>
    semanticURLCandidates(raw).some(url => {
      const query = new Map(
        [...url.searchParams].map(([name, value]) => [name.toLowerCase(), value.toLowerCase()]),
      )
      return query.get('asin') === expectedASIN && query.get('ref_') === expectedRef
    }),
  )
}

function allObservedURLs(chain) {
  return (chain ?? []).flatMap(hop => [hop.url, hop.location].filter(Boolean))
}

/**
 * Evaluates a fully followed main-frame redirect chain.
 *
 * Alias library path loss is an expected migration hazard, not proof that the
 * canonical storefront is broken. It is therefore returned as an explicit
 * warning. Canonical library path loss and reader identity loss are failures.
 */
export function evaluateRoute({
  storefront,
  purpose,
  chain,
  libraryPath,
  asin,
  readerRef,
  relatedURLs = [],
  redirectLimitReached = false,
}) {
  const failures = []
  const warnings = []
  if (!Array.isArray(chain) || chain.length === 0) {
    return { ok: false, failures: ['empty_redirect_chain'], warnings }
  }
  if (redirectLimitReached) failures.push('redirect_limit_reached')

  const observedURLs = [...allObservedURLs(chain), ...relatedURLs]
  if (observedURLs.some(rawURL => {
    try {
      return normalizedPath(new URL(rawURL)).includes('/kindle-library/not-supported')
    } catch {
      return false
    }
  })) {
    // Amazon serves this route to non-browser user agents. Treat it as a broken
    // verifier/WebView signature, not evidence that the regional site is down.
    failures.push('verifier_browser_ua_rejected')
  }

  for (const rawURL of observedURLs) {
    if (!routeBelongsToStorefront(rawURL, storefront)) {
      failures.push('cross_or_untrusted_storefront')
      break
    }
  }

  const finalHop = chain.at(-1)
  if (!(Number(finalHop.status) >= 200 && Number(finalHop.status) < 400)) {
    failures.push(`terminal_http_${Number(finalHop.status) || 0}`)
  }
  if (isRedirectStatus(finalHop.status) && !finalHop.location) {
    failures.push('redirect_without_location')
  }

  if (purpose === 'canonical-library' || purpose === 'alias-library') {
    // A canonical library entry may intentionally land on `/landing`; its
    // visible sign-in link must then carry an exact return_to back to the
    // canonical library. An alias already lost the path before that page, so a
    // later button must not hide the migration hazard.
    const semanticLinks = purpose === 'canonical-library' ? relatedURLs : []
    const carriesPath = carriesLibraryPath(chain, libraryPath, semanticLinks)
    if (!carriesPath && purpose === 'alias-library') {
      warnings.push('alias_library_path_lost')
    } else if (!carriesPath) {
      failures.push('canonical_library_path_lost')
    }
  }

  if (purpose === 'canonical-landing') {
    if (relatedURLs.length === 0) {
      failures.push('canonical_landing_signin_missing')
    } else if (!carriesLibraryPath([], libraryPath, relatedURLs)) {
      failures.push('canonical_landing_return_to_invalid')
    }
  }

  if (purpose === 'canonical-reader' || purpose === 'alias-reader') {
    if (!carriesReaderIdentity(chain, asin, readerRef, relatedURLs)) {
      failures.push('reader_identity_lost')
    }
  }

  return {
    ok: failures.length === 0,
    failures: [...new Set(failures)],
    warnings: [...new Set(warnings)],
  }
}

export function safeRouteLabel(rawURL) {
  try {
    const url = new URL(rawURL)
    return `${normalizeHost(url.hostname) ?? 'invalid'}${url.pathname || '/'}`
  } catch {
    return 'invalid-url'
  }
}
