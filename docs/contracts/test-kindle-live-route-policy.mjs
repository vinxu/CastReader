#!/usr/bin/env node

import assert from 'node:assert/strict'
import {
  carriesLibraryPath,
  carriesReaderIdentity,
  evaluateRoute,
  freshLibraryURL,
  freshReaderURL,
  routeBelongsToStorefront,
  safeRouteLabel,
} from './kindle-live-route-policy.mjs'

const storefront = {
  id: 'it',
  canonicalHost: 'leggi.amazon.it',
  aliasHosts: ['read.amazon.it'],
}
const libraryPath = '/kindle-library'
const asin = 'B012345678'
const readerRef = 'kwl_kr_iv_rec_1'

assert.equal(
  freshLibraryURL(storefront, libraryPath),
  'https://leggi.amazon.it/kindle-library',
)
assert.equal(
  freshReaderURL(storefront, '/', asin, readerRef),
  'https://leggi.amazon.it/?asin=B012345678&ref_=kwl_kr_iv_rec_1',
)

const canonicalLibraryChain = [
  {
    url: 'https://leggi.amazon.it/kindle-library',
    status: 302,
    location: 'https://leggi.amazon.it/landing',
  },
  { url: 'https://leggi.amazon.it/landing', status: 200, location: null },
]
const canonicalLibrarySignIn =
  'https://www.amazon.it/ap/signin?' +
  'openid.return_to=https%3A%2F%2Fleggi.amazon.it%2Fkindle-library'
assert.equal(carriesLibraryPath(canonicalLibraryChain, libraryPath), false)
assert.equal(
  carriesLibraryPath(canonicalLibraryChain, libraryPath, [canonicalLibrarySignIn]),
  true,
)
assert.deepEqual(
  evaluateRoute({
    storefront,
    purpose: 'canonical-library',
    chain: canonicalLibraryChain,
    libraryPath,
    asin,
    readerRef,
    relatedURLs: [canonicalLibrarySignIn],
  }),
  { ok: true, failures: [], warnings: [] },
)

const canonicalLandingChain = [
  { url: 'https://leggi.amazon.it/landing', status: 200, location: null },
]
assert.deepEqual(
  evaluateRoute({
    storefront,
    purpose: 'canonical-landing',
    chain: canonicalLandingChain,
    libraryPath,
    asin,
    readerRef,
    relatedURLs: [canonicalLibrarySignIn],
  }),
  { ok: true, failures: [], warnings: [] },
)
assert.deepEqual(
  evaluateRoute({
    storefront,
    purpose: 'canonical-landing',
    chain: canonicalLandingChain,
    libraryPath,
    asin,
    readerRef,
  }).failures,
  ['canonical_landing_signin_missing'],
)
const landingWithoutLibraryReturn =
  'https://www.amazon.it/ap/signin?' +
  'openid.return_to=https%3A%2F%2Fleggi.amazon.it%2F'
assert.deepEqual(
  evaluateRoute({
    storefront,
    purpose: 'canonical-landing',
    chain: canonicalLandingChain,
    libraryPath,
    asin,
    readerRef,
    relatedURLs: [landingWithoutLibraryReturn],
  }).failures,
  ['canonical_landing_return_to_invalid'],
)
const landingWithUnrelatedLibraryValue = new URL('https://www.amazon.it/ap/signin')
landingWithUnrelatedLibraryValue.searchParams.set(
  'unrelated',
  'https://leggi.amazon.it/kindle-library',
)
assert.deepEqual(
  evaluateRoute({
    storefront,
    purpose: 'canonical-landing',
    chain: canonicalLandingChain,
    libraryPath,
    asin,
    readerRef,
    relatedURLs: [landingWithUnrelatedLibraryValue.href],
  }).failures,
  ['canonical_landing_return_to_invalid'],
  'an unrelated query value must not masquerade as a login return_to',
)

const missingCanonicalReturnTo = evaluateRoute({
  storefront,
  purpose: 'canonical-library',
  chain: canonicalLibraryChain,
  libraryPath,
  asin,
  readerRef,
})
assert.equal(missingCanonicalReturnTo.ok, false)
assert.deepEqual(missingCanonicalReturnTo.failures, ['canonical_library_path_lost'])

const aliasLibraryChain = [
  {
    url: 'https://read.amazon.it/kindle-library',
    status: 301,
    location: 'https://leggi.amazon.it:443/',
  },
  {
    url: 'https://leggi.amazon.it:443/',
    status: 302,
    location: 'https://leggi.amazon.it/landing',
  },
  { url: 'https://leggi.amazon.it/landing', status: 200, location: null },
]
const aliasLibrary = evaluateRoute({
  storefront,
  purpose: 'alias-library',
  chain: aliasLibraryChain,
  libraryPath,
  asin,
  readerRef,
  relatedURLs: [canonicalLibrarySignIn],
})
assert.equal(aliasLibrary.ok, true)
assert.deepEqual(aliasLibrary.failures, [])
assert.deepEqual(aliasLibrary.warnings, ['alias_library_path_lost'])

const canonicalReader =
  'https://leggi.amazon.it/?asin=B012345678&ref_=kwl_kr_iv_rec_1'
const readerSignIn =
  'https://www.amazon.it/ap/signin?' +
  'openid.return_to=https%3A%2F%2Fleggi.amazon.it%2F%3Fasin%3D' +
  'B012345678%26ref_%3Dkwl_kr_iv_rec_1'
const aliasReaderChain = [
  {
    url: 'https://read.amazon.it/?asin=B012345678&ref_=kwl_kr_iv_rec_1',
    status: 301,
    location: 'https://leggi.amazon.it:443/?asin=B012345678&ref_=kwl_kr_iv_rec_1',
  },
  {
    url: canonicalReader,
    status: 302,
    location: readerSignIn,
  },
  { url: readerSignIn, status: 200, location: null },
]
assert.equal(carriesReaderIdentity(aliasReaderChain, asin, readerRef), true)
assert.equal(
  evaluateRoute({
    storefront,
    purpose: 'alias-reader',
    chain: aliasReaderChain,
    libraryPath,
    asin,
    readerRef,
  }).ok,
  true,
)

const readerWithoutRef = evaluateRoute({
  storefront,
  purpose: 'canonical-reader',
  chain: [
    {
      url: canonicalReader,
      status: 302,
      location: 'https://www.amazon.it/ap/signin?openid.return_to=https%3A%2F%2Fleggi.amazon.it%2F%3Fasin%3DB012345678',
    },
    {
      url: 'https://www.amazon.it/ap/signin?openid.return_to=https%3A%2F%2Fleggi.amazon.it%2F%3Fasin%3DB012345678',
      status: 200,
      location: null,
    },
  ],
  libraryPath,
  asin,
  readerRef,
})
assert.equal(readerWithoutRef.ok, false)
assert.deepEqual(readerWithoutRef.failures, ['reader_identity_lost'])

assert.equal(
  routeBelongsToStorefront(
    canonicalLibrarySignIn,
    storefront,
  ),
  true,
)
assert.equal(
  routeBelongsToStorefront(
    'https://www.amazon.com/ap/signin?openid.return_to=x',
    storefront,
  ),
  false,
)
const crossMarketLibraryReturn =
  'https://www.amazon.it/ap/signin?' +
  'openid.return_to=https%3A%2F%2Fread.amazon.com%2Fkindle-library'
const phishingLibraryReturn =
  'https://www.amazon.it/ap/signin?' +
  'openid.return_to=https%3A%2F%2Fleggi.amazon.it.phish.example%2Fkindle-library'
const malformedLibraryReturn =
  'https://www.amazon.it/ap/signin?openid.return_to=%ZZ'
assert.equal(routeBelongsToStorefront(crossMarketLibraryReturn, storefront), false)
assert.equal(routeBelongsToStorefront(phishingLibraryReturn, storefront), false)
assert.equal(routeBelongsToStorefront(malformedLibraryReturn, storefront), false)

const doubleEncodedCanonicalReturn = new URL('https://www.amazon.it/ap/signin')
doubleEncodedCanonicalReturn.searchParams.set(
  'openid.return_to',
  encodeURIComponent('https://leggi.amazon.it/kindle-library'),
)
assert.equal(
  routeBelongsToStorefront(doubleEncodedCanonicalReturn.href, storefront),
  true,
)

const nestedCrossLibrary = evaluateRoute({
  storefront,
  purpose: 'canonical-library',
  chain: canonicalLibraryChain,
  libraryPath,
  asin,
  readerRef,
  relatedURLs: [crossMarketLibraryReturn],
})
assert.equal(nestedCrossLibrary.ok, false)
assert.equal(
  nestedCrossLibrary.failures.includes('cross_or_untrusted_storefront'),
  true,
  'an outer same-market auth URL cannot hide a cross-storefront return_to',
)

const nestedCrossReaderSignIn =
  'https://www.amazon.it/ap/signin?' +
  'openid.return_to=https%3A%2F%2Fread.amazon.com%2F%3Fasin%3D' +
  'B012345678%26ref_%3Dkwl_kr_iv_rec_1'
const nestedCrossReader = evaluateRoute({
  storefront,
  purpose: 'canonical-reader',
  chain: [
    { url: canonicalReader, status: 302, location: nestedCrossReaderSignIn },
    { url: nestedCrossReaderSignIn, status: 200, location: null },
  ],
  libraryPath,
  asin,
  readerRef,
})
assert.equal(nestedCrossReader.ok, false)
assert.equal(nestedCrossReader.failures.includes('reader_identity_lost'), false)
assert.equal(
  nestedCrossReader.failures.includes('cross_or_untrusted_storefront'),
  true,
  'preserved ASIN/ref cannot hide a cross-storefront return_to',
)
const crossStorefront = evaluateRoute({
  storefront,
  purpose: 'canonical-reader',
  chain: [
    {
      url: canonicalReader,
      status: 302,
      location: 'https://www.amazon.com/ap/signin?openid.return_to=x',
    },
    {
      url: 'https://www.amazon.com/ap/signin?openid.return_to=x',
      status: 200,
      location: null,
    },
  ],
  libraryPath,
  asin,
  readerRef,
})
assert.equal(crossStorefront.ok, false)
assert.equal(crossStorefront.failures.includes('cross_or_untrusted_storefront'), true)

const unsupportedUA = evaluateRoute({
  storefront,
  purpose: 'canonical-library',
  chain: [
    {
      url: 'https://leggi.amazon.it/kindle-library',
      status: 302,
      location: 'https://leggi.amazon.it/kindle-library/not-supported',
    },
    {
      url: 'https://leggi.amazon.it/kindle-library/not-supported',
      status: 200,
      location: null,
    },
  ],
  libraryPath,
  asin,
  readerRef,
})
assert.equal(unsupportedUA.ok, false)
assert.equal(unsupportedUA.failures.includes('verifier_browser_ua_rejected'), true)

assert.equal(
  safeRouteLabel('https://leggi.amazon.it/?asin=PRIVATE&ref_=SECRET'),
  'leggi.amazon.it/',
  'console labels must never contain query values',
)

console.log(
  'PASS Kindle live-route policy: canonical entries, alias path loss, nested return_to, ' +
  'reader identity, storefront isolation, UA rejection, and privacy-safe labels',
)
