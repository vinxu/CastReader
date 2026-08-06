//
//  KindleStorefrontTests.swift
//  CastReaderTests
//
//  Kindle marketplace URL, recommendation, migration, and shared-data contract.
//

import XCTest
import WebKit
@testable import CastReader

final class KindleStorefrontTests: XCTestCase {
    private struct Contract: Decodable {
        struct Paths: Decodable, Equatable {
            let library: String
            let reader: String
        }

        struct Storefront: Decodable, Equatable {
            let id: String
            let marketplaceRegion: String
            let canonicalHost: String
            let aliasHosts: [String]
            let displayName: String
            let entryEnabled: Bool
            let entryDisabledReason: String?
        }

        let contractID: String
        let schemaVersion: Int
        let fallbackStorefrontID: String
        let readerRef: String
        let paths: Paths
        let storefronts: [Storefront]
        let regionToStorefront: [String: String]
        let languageCandidateOrder: [String: [String]]
        let excludedAppLanguages: [String]
    }

    private struct ContractCases: Decodable {
        struct Match: Decodable {
            let input: String
            let expectedStorefrontID: String
        }

        let contractID: String
        let schemaVersion: Int
        let expectedStorefrontCount: Int
        let expectedRecognizedHostCount: Int
        let expectedEntryEnabledStorefrontCount: Int
        let positiveHostCases: [Match]
        let securityNegativeHosts: [String]
        let positiveURLCases: [Match]
        let securityNegativeURLs: [String]
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadContract() throws -> Contract {
        let url = repositoryRoot
            .appendingPathComponent("docs/contracts/kindle-storefronts-v1.json")
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    }

    private func loadCases() throws -> ContractCases {
        let url = repositoryRoot
            .appendingPathComponent("docs/contracts/kindle-storefront-contract-cases-v1.json")
        return try JSONDecoder().decode(ContractCases.self, from: Data(contentsOf: url))
    }

    func testSharedJSONHasCompleteStableCatalog() throws {
        let contract = try loadContract()
        let cases = try loadCases()

        XCTAssertEqual(contract.contractID, "castreader-kindle-storefronts")
        XCTAssertEqual(contract.schemaVersion, 1)
        XCTAssertEqual(contract.fallbackStorefrontID, "us")
        XCTAssertEqual(contract.readerRef, "kwl_kr_iv_rec_1")
        XCTAssertEqual(cases.contractID, "castreader-kindle-storefront-test-cases")
        XCTAssertEqual(cases.schemaVersion, 1)
        XCTAssertEqual(contract.paths, .init(library: "/kindle-library", reader: "/"))
        XCTAssertEqual(contract.storefronts.count, 14)
        XCTAssertEqual(contract.storefronts.count, cases.expectedStorefrontCount)
        XCTAssertEqual(contract.storefronts.filter(\.entryEnabled).count, 13)
        XCTAssertEqual(
            contract.storefronts.filter(\.entryEnabled).count,
            cases.expectedEntryEnabledStorefrontCount
        )

        let expectedIDs = [
            "us", "uk", "ca", "au", "jp", "de", "fr", "it", "es", "in",
            "br", "mx", "nl", "cn",
        ]
        XCTAssertEqual(contract.storefronts.map(\.id), expectedIDs)
        XCTAssertEqual(Set(contract.storefronts.map(\.id)).count, expectedIDs.count)

        var allHosts: [String] = []
        for storefront in contract.storefronts {
            XCTAssertNotNil(
                storefront.id.range(of: #"^[a-z]{2}$"#, options: .regularExpression)
            )
            XCTAssertNotNil(
                storefront.marketplaceRegion.range(
                    of: #"^[A-Z]{2}$"#,
                    options: .regularExpression
                )
            )
            XCTAssertFalse(storefront.canonicalHost.isEmpty)
            XCTAssertEqual(storefront.canonicalHost, storefront.canonicalHost.lowercased())
            XCTAssertFalse(storefront.displayName.isEmpty)
            XCTAssertFalse(storefront.aliasHosts.contains(storefront.canonicalHost))
            XCTAssertEqual(
                Set(storefront.aliasHosts).count,
                storefront.aliasHosts.count,
                "duplicate alias in \(storefront.id)"
            )
            for host in [storefront.canonicalHost] + storefront.aliasHosts {
                XCTAssertNotNil(
                    host.range(
                        of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)*$"#,
                        options: .regularExpression
                    ),
                    "invalid normalized host \(host)"
                )
                allHosts.append(host)
            }
        }
        XCTAssertEqual(allHosts.count, 21)
        XCTAssertEqual(allHosts.count, cases.expectedRecognizedHostCount)
        XCTAssertEqual(Set(allHosts).count, allHosts.count)

        let disabled = contract.storefronts.filter { !$0.entryEnabled }
        XCTAssertEqual(disabled.map(\.id), ["cn"])
        XCTAssertEqual(disabled.first?.entryDisabledReason, "kindle_china_shutdown")
        XCTAssertFalse(contract.regionToStorefront.values.contains("cn"))
        XCTAssertFalse(contract.languageCandidateOrder.values.flatMap { $0 }.contains("cn"))
        XCTAssertEqual(Set(contract.excludedAppLanguages), ["zh", "zh-Hans"])
    }

    func testRuntimeCatalogExactlyProjectsSharedJSON() throws {
        let contract = try loadContract()
        XCTAssertEqual(KindleStorefront.all.count, contract.storefronts.count)

        for (runtime, shared) in zip(KindleStorefront.all, contract.storefronts) {
            XCTAssertEqual(runtime.id, shared.id)
            XCTAssertEqual(runtime.marketplaceRegion, shared.marketplaceRegion)
            XCTAssertEqual(runtime.canonicalHost, shared.canonicalHost)
            XCTAssertEqual(runtime.aliasHosts, shared.aliasHosts)
            XCTAssertEqual(runtime.displayName, shared.displayName)
            XCTAssertEqual(runtime.entryEnabled, shared.entryEnabled)
            XCTAssertEqual(runtime.entryDisabledReason, shared.entryDisabledReason)
        }
        XCTAssertEqual(KindleStorefront.selectable.count, 13)
        XCTAssertEqual(KindleStorefront.us.id, "us")
        XCTAssertEqual(KindleStorefront.readerReferenceValue, "kwl_kr_iv_rec_1")
    }

    func testEveryCanonicalAndAliasHostMatchesExactly() throws {
        let contract = try loadContract()
        let expectedHostOwners = Dictionary(
            uniqueKeysWithValues: contract.storefronts.flatMap { storefront in
                ([storefront.canonicalHost] + storefront.aliasHosts).map {
                    ($0, storefront.id)
                }
            }
        )

        XCTAssertEqual(expectedHostOwners.count, 21)
        for (host, expectedID) in expectedHostOwners {
            XCTAssertEqual(KindleStorefront.storefront(host: host)?.id, expectedID)
            XCTAssertEqual(
                KindleStorefront.storefront(host: host.uppercased())?.id,
                expectedID
            )
            XCTAssertEqual(
                KindleStorefront.storefront(host: host + ".")?.id,
                expectedID
            )
            XCTAssertTrue(KindleStorefront.matches(host: host))
            XCTAssertTrue(
                try XCTUnwrap(KindleStorefront.storefront(id: expectedID))
                    .matches(host: host)
            )
        }

        let fixedTruthTable = [
            "read.amazon.com": "us",
            "read.amazon.co.uk": "uk",
            "read.amazon.ca": "ca",
            "read.amazon.com.au": "au",
            "read.amazon.co.jp": "jp",
            "lesen.amazon.de": "de",
            "read.amazon.de": "de",
            "lire.amazon.fr": "fr",
            "read.amazon.fr": "fr",
            "leggi.amazon.it": "it",
            "read.amazon.it": "it",
            "leer.amazon.es": "es",
            "read.amazon.es": "es",
            "read.amazon.in": "in",
            "ler.amazon.com.br": "br",
            "read.amazon.com.br": "br",
            "leer.amazon.com.mx": "mx",
            "read.amazon.com.mx": "mx",
            "lezen.amazon.nl": "nl",
            "read.amazon.nl": "nl",
            "read.amazon.cn": "cn",
        ]
        XCTAssertEqual(expectedHostOwners, fixedTruthTable)
    }

    func testHostAndURLSecurityNegativeCasesAreRejected() throws {
        let cases = try loadCases()
        for host in cases.securityNegativeHosts {
            XCTAssertNil(
                KindleStorefront.storefront(host: host),
                "unsafe host matched: \(host)"
            )
        }
        for testCase in cases.positiveHostCases {
            XCTAssertEqual(
                KindleStorefront.storefront(host: testCase.input)?.id,
                testCase.expectedStorefrontID
            )
        }

        for rawURL in cases.securityNegativeURLs {
            XCTAssertNil(
                KindleStorefront.storefront(url: URL(string: rawURL)),
                "unsafe URL matched: \(rawURL)"
            )
        }
        let additionalUnsafeURLs = [
            "https://user@read.amazon.com/?asin=B012345678",
            "https://user:secret@read.amazon.com/?asin=B012345678",
            "http://leer.amazon.es/?asin=B012345678",
            "https://ler.amazon.com.br:444/?asin=B012345678",
        ]
        for rawURL in additionalUnsafeURLs {
            XCTAssertNil(
                KindleStorefront.storefront(url: URL(string: rawURL)),
                "unsafe URL matched: \(rawURL)"
            )
        }

        for testCase in cases.positiveURLCases {
            XCTAssertEqual(
                KindleStorefront.storefront(url: URL(string: testCase.input))?.id,
                testCase.expectedStorefrontID
            )
        }
    }

    func testEveryStorefrontBuildsCanonicalLibraryAndReaderURLs() throws {
        let contract = try loadContract()
        for storefront in KindleStorefront.all {
            let library = storefront.libraryURL
            XCTAssertEqual(library.scheme, "https")
            XCTAssertEqual(library.host, storefront.canonicalHost)
            XCTAssertEqual(library.path, contract.paths.library)
            XCTAssertNil(library.user)
            XCTAssertNil(library.password)
            XCTAssertNil(library.port)
            XCTAssertNil(library.query)

            let reader = storefront.readerURL(asin: " b012345678 ")
            let components = try XCTUnwrap(
                URLComponents(url: reader, resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, storefront.canonicalHost)
            XCTAssertEqual(components.path, contract.paths.reader)
            XCTAssertNil(components.user)
            XCTAssertNil(components.password)
            XCTAssertNil(components.port)
            XCTAssertEqual(
                components.queryItems,
                [
                    URLQueryItem(name: "asin", value: "B012345678"),
                    URLQueryItem(
                        name: "ref_",
                        value: KindleStorefront.readerReferenceValue
                    ),
                ]
            )
        }
    }

    func testEightNonChineseLanguageOrdersAndRegionPriorityMatchContract() throws {
        let contract = try loadContract()
        let expectedLanguageOrders = [
            "en": ["us", "uk", "ca", "au", "in"],
            "es": ["es", "mx", "us"],
            "pt-BR": ["br", "us"],
            "ja": ["jp", "us"],
            "de": ["de", "us"],
            "fr": ["fr", "ca", "us"],
            "it": ["it", "us"],
            "hi": ["in", "us"],
        ]
        XCTAssertEqual(contract.languageCandidateOrder, expectedLanguageOrders)
        XCTAssertEqual(contract.languageCandidateOrder.count, 8)

        let enabledIDs = contract.storefronts.filter(\.entryEnabled).map(\.id)
        for (language, preferredIDs) in expectedLanguageOrders {
            let expectedFullOrder = deduplicated(preferredIDs + enabledIDs)
            let actual = KindleStorefront.orderedCandidates(
                deviceRegion: nil,
                languageCode: language
            ).map(\.id)
            XCTAssertEqual(actual, expectedFullOrder, "language \(language)")
            XCTAssertFalse(actual.contains("cn"))
        }

        for (region, expectedID) in contract.regionToStorefront {
            let actual = KindleStorefront.orderedCandidates(
                deviceRegion: region.lowercased(),
                languageCode: "en"
            )
            XCTAssertEqual(actual.first?.id, expectedID, "region \(region)")
            XCTAssertFalse(actual.contains { !$0.entryEnabled })
        }
        XCTAssertEqual(
            KindleStorefront.orderedCandidates(
                deviceRegion: "ZZ",
                languageCode: "es"
            ).first?.id,
            "es"
        )
    }

    func testDynamicRecommendationIgnoresFreshUSPlaceholderButPreservesRealBinding() {
        let japanContext = KindleStorefrontRecommendationContext(
            regionCode: "JP",
            preferredLanguages: ["ja-JP", "en-US"],
            appLanguageCode: "ja",
            timeZoneIdentifier: "Asia/Tokyo",
            secondsFromGMT: 9 * 60 * 60
        )

        let fresh = KindleStorefrontRecommender.recommend(
            context: japanContext,
            authoritativeBoundStorefrontID: nil
        )
        XCTAssertEqual(fresh.recommended.id, "jp")
        XCTAssertEqual(fresh.candidates.first?.id, "jp")
        XCTAssertEqual(Set(fresh.candidates.map(\.id)).count, fresh.candidates.count)
        XCTAssertEqual(fresh.candidates.count, KindleStorefront.selectable.count)
        XCTAssertFalse(fresh.candidates.contains { !$0.entryEnabled })

        let alreadyBound = KindleStorefrontRecommender.recommend(
            context: japanContext,
            authoritativeBoundStorefrontID: "us"
        )
        XCTAssertEqual(
            alreadyBound.recommended.id,
            "us",
            "a real account binding remains authoritative even after locale changes"
        )
        XCTAssertEqual(alreadyBound.candidates.first?.id, "us")
        XCTAssertEqual(
            alreadyBound.candidates.filter { $0.id == "us" }.count,
            1,
            "prepending the bound site must not duplicate it in the dynamic ranking"
        )
    }

    func testDynamicRecommendationCombinesLanguageRegionAndTimeZoneEvidence() {
        let mexicanSpanish = KindleStorefrontRecommendationContext(
            regionCode: nil,
            preferredLanguages: ["es-MX", "es-ES", "en-US"],
            appLanguageCode: "es",
            timeZoneIdentifier: "America/Mexico_City",
            secondsFromGMT: -6 * 60 * 60
        )
        XCTAssertEqual(
            KindleStorefrontRecommender.recommend(context: mexicanSpanish)
                .recommended.id,
            "mx"
        )

        let residentInSpain = KindleStorefrontRecommendationContext(
            regionCode: "ES",
            preferredLanguages: ["es-MX", "en-US"],
            appLanguageCode: "es",
            timeZoneIdentifier: "America/Mexico_City",
            secondsFromGMT: -6 * 60 * 60
        )
        XCTAssertEqual(
            KindleStorefrontRecommender.recommend(context: residentInSpain)
                .recommended.id,
            "es",
            "Locale.region must outrank weaker language and time-zone hints"
        )

        let offsetOnly = KindleStorefrontRecommendationContext(
            regionCode: nil,
            preferredLanguages: [],
            appLanguageCode: "zh-Hans",
            timeZoneIdentifier: nil,
            secondsFromGMT: 5 * 60 * 60 + 30 * 60
        )
        XCTAssertEqual(
            KindleStorefrontRecommender.recommend(context: offsetOnly)
                .recommended.id,
            "in",
            "secondsFromGMT remains a deterministic last-resort signal"
        )
    }

    func testRecommendationContextReadsLocaleAndTimeZoneWithoutGlobalState() throws {
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let winter = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC
        let context = KindleStorefrontRecommendationContext(
            locale: Locale(identifier: "en_GB"),
            preferredLanguages: ["en-GB", "en-US"],
            appLanguageCode: "en",
            timeZone: london,
            date: winter
        )

        XCTAssertEqual(context.regionCode, "GB")
        XCTAssertEqual(context.timeZoneIdentifier, "Europe/London")
        XCTAssertEqual(context.secondsFromGMT, 0)
        XCTAssertEqual(
            KindleStorefrontRecommender.recommend(context: context)
                .recommended.id,
            "uk"
        )
    }

    func testChinaEnvironmentUsesEnabledEastAsiaFallbacksInsteadOfCatalogOrder() {
        let context = KindleStorefrontRecommendationContext(
            regionCode: "CN",
            preferredLanguages: ["zh-Hans-CN"],
            appLanguageCode: "zh-Hans",
            timeZoneIdentifier: "Asia/Shanghai",
            secondsFromGMT: 8 * 60 * 60
        )
        let result = KindleStorefrontRecommender.recommend(context: context)

        XCTAssertEqual(Array(result.candidates.prefix(3).map(\.id)), ["us", "jp", "au"])
        XCTAssertFalse(
            result.candidates.contains { $0.id == "cn" },
            "Amazon.cn remains recognition-only and must never become an onboarding destination"
        )
        XCTAssertEqual(Set(result.candidates.map(\.id)).count, result.candidates.count)
    }

    func testChinaIsRecognitionOnlyAndNeverSuggested() {
        let china = KindleStorefront.storefront(id: "cn")
        XCTAssertEqual(china?.canonicalHost, "read.amazon.cn")
        XCTAssertEqual(china?.entryEnabled, false)
        XCTAssertEqual(KindleStorefront.storefront(host: "read.amazon.cn")?.id, "cn")
        XCTAssertNil(KindleStorefront.entry(id: "cn"))
        XCTAssertNil(
            KindleStorefront.entry(url: URL(string: "https://read.amazon.cn/kindle-library"))
        )
        XCTAssertFalse(KindleStorefront.selectable.contains { $0.id == "cn" })
        XCTAssertTrue(
            KindleBookValidator.isKindleReaderPath(
                "https://read.amazon.cn/reader/index.html?asin=B012345678"
            ),
            "legacy China reader links remain recognizable for migration"
        )

        let legacyChinaBook = makeBook(
            id: "B012345678",
            readerURL: "https://read.amazon.cn/?asin=B012345678",
            storefrontID: "cn"
        )
        XCTAssertEqual(
            KindleBookValidator.repairedReaderURL(
                for: legacyChinaBook,
                preferLastRead: false
            ),
            "https://read.amazon.com/?asin=B012345678&ref_=kwl_kr_iv_rec_1",
            "recognition-only China must never survive as a repaired navigation"
        )
        let canonicalHostMapData = try! XCTUnwrap(
            KindleStorefront.javaScriptCanonicalHostMap.data(using: .utf8)
        )
        let canonicalHostMap = try! XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalHostMapData)
                as? [String: String]
        )
        XCTAssertEqual(
            canonicalHostMap["read.amazon.cn"],
            "read.amazon.com",
            "scraping a legacy China page must synthesize an enabled reader entry"
        )

        for language in ["en", "es", "pt-BR", "ja", "de", "fr", "it", "hi", "zh-Hans"] {
            XCTAssertFalse(
                KindleStorefront.orderedCandidates(
                    deviceRegion: "CN",
                    languageCode: language
                ).contains { $0.id == "cn" }
            )
        }
    }

    func testNavigationAllowsOnlyTheExpectedEntryEnabledStorefront() {
        let localizedRedirectPairs = [
            ("de", "https://read.amazon.de/kindle-library", "https://lesen.amazon.de/kindle-library"),
            ("fr", "https://read.amazon.fr/kindle-library", "https://lire.amazon.fr/kindle-library"),
            ("it", "https://read.amazon.it/kindle-library", "https://leggi.amazon.it/kindle-library"),
            ("mx", "https://read.amazon.com.mx/kindle-library", "https://leer.amazon.com.mx/kindle-library"),
            ("nl", "https://read.amazon.nl/kindle-library", "https://lezen.amazon.nl/kindle-library"),
        ]
        for (storefrontID, legacyEntry, localizedDestination) in localizedRedirectPairs {
            XCTAssertTrue(
                KindleStorefrontNavigationPolicy.allows(
                    URL(string: legacyEntry),
                    expectedStorefrontID: storefrontID
                )
            )
            XCTAssertTrue(
                KindleStorefrontNavigationPolicy.allows(
                    URL(string: localizedDestination),
                    expectedStorefrontID: storefrontID
                ),
                "the live Amazon redirect must remain inside storefront \(storefrontID)"
            )
        }

        XCTAssertTrue(
            KindleStorefrontNavigationPolicy.allows(
                URL(string: "https://read.amazon.es/?asin=B012345678"),
                expectedStorefrontID: "es"
            ),
            "a same-storefront alias is a valid navigation"
        )
        XCTAssertFalse(
            KindleStorefrontNavigationPolicy.allows(
                URL(string: "https://read.amazon.com/?asin=B012345678"),
                expectedStorefrontID: "es"
            )
        )
        XCTAssertFalse(
            KindleStorefrontNavigationPolicy.allows(
                URL(string: "https://read.amazon.cn/reader/index.html?asin=B012345678"),
                expectedStorefrontID: "us"
            )
        )
        XCTAssertFalse(
            KindleStorefrontNavigationPolicy.allows(
                URL(string: "https://read.amazon.phish.com/?asin=B012345678"),
                expectedStorefrontID: "us"
            )
        )
        XCTAssertTrue(
            KindleStorefrontNavigationPolicy.allowsMainFrame(
                URL(string: "https://www.amazon.es/ap/signin?openid.return_to=https%3A%2F%2Fleer.amazon.es"),
                expectedStorefrontID: "es"
            ),
            "a secure Amazon-owned authentication endpoint is the only non-reader exception"
        )
        XCTAssertTrue(
            KindleStorefrontNavigationPolicy.allowsMainFrame(
                URL(string: "https://www.amazon.es/ap/cvf"),
                expectedStorefrontID: "es"
            ),
            "same-marketplace challenge pages may omit an explicit return target"
        )
        XCTAssertFalse(
            KindleStorefrontNavigationPolicy.allowsMainFrame(
                URL(string: "https://www.amazon.es/ap/signin?openid.return_to=https%3A%2F%2Fread.amazon.com%2Fkindle-library"),
                expectedStorefrontID: "es"
            ),
            "an auth page cannot smuggle a return target into another Kindle marketplace"
        )
        XCTAssertTrue(
            KindleStorefrontNavigationPolicy.resemblesAmazonAuthenticationURL(
                URL(string: "https://www.amazon.es/ap/signin?openid.return_to=https%3A%2F%2Fread.amazon.com%2Fkindle-library")
            ),
            "a rejected auth redirect remains classifiable without becoming allowed"
        )
        XCTAssertFalse(
            KindleStorefrontNavigationPolicy.allowsMainFrame(
                URL(string: "https://www.amazon.com/ap/signin?openid.return_to=https%3A%2F%2Fleer.amazon.es%2Fkindle-library"),
                expectedStorefrontID: "es"
            ),
            "the authentication host itself must belong to the expected marketplace"
        )
        XCTAssertFalse(
            KindleStorefrontNavigationPolicy.allowsMainFrame(
                URL(string: "https://www.amazon.es/ap/signin?return_to=https%3A%2F%2Fleer.amazon.es.phish.example%2Fkindle-library"),
                expectedStorefrontID: "es"
            ),
            "return_to uses the same exact-host boundary as ordinary navigation"
        )
        XCTAssertFalse(
            KindleStorefrontNavigationPolicy.allowsMainFrame(
                URL(string: "https://amazon.es.phish.example/ap/signin?openid.return_to=x"),
                expectedStorefrontID: "es"
            )
        )
        XCTAssertFalse(
            KindleStorefrontNavigationPolicy.allowsMainFrame(
                URL(string: "http://www.amazon.es/ap/signin?openid.return_to=x"),
                expectedStorefrontID: "es"
            )
        )
        XCTAssertFalse(
            KindleStorefrontNavigationPolicy.allowsMainFrame(
                URL(string: "https://read.amazon.com/ap/signin?openid.return_to=x"),
                expectedStorefrontID: "es"
            ),
            "a recognized cross-storefront host cannot use an auth-looking path to bypass ownership"
        )
        XCTAssertFalse(
            KindleStorefrontNavigationPolicy.allowsMainFrame(
                URL(string: "https://read.amazon.cn/ap/signin?openid.return_to=x"),
                expectedStorefrontID: "us"
            ),
            "recognition-only China cannot use the authentication exception"
        )
        XCTAssertTrue(
            KindleStorefrontNavigationPolicy.isExactLibraryURL(
                URL(string: "https://leer.amazon.es/kindle-library/?ref_=test"),
                expectedStorefrontID: "es"
            )
        )
        XCTAssertFalse(
            KindleStorefrontNavigationPolicy.isExactLibraryURL(
                URL(string: "https://leer.amazon.es/help/kindle-library"),
                expectedStorefrontID: "es"
            )
        )
    }

    func testForcedReauthenticationWebsiteDataIsScopedToOneMarketplace() throws {
        let italy = try XCTUnwrap(KindleStorefront.storefront(id: "it"))
        XCTAssertTrue(
            KindleStorefront.isAmazonWebsiteDataDomain("amazon.it", for: italy)
        )
        XCTAssertTrue(
            KindleStorefront.isAmazonWebsiteDataDomain(".amazon.it", for: italy)
        )
        XCTAssertTrue(
            KindleStorefront.isAmazonWebsiteDataDomain("leggi.amazon.it", for: italy)
        )
        XCTAssertFalse(
            KindleStorefront.isAmazonWebsiteDataDomain("amazon.com", for: italy)
        )
        XCTAssertFalse(
            KindleStorefront.isAmazonWebsiteDataDomain("amazon.de", for: italy)
        )
        XCTAssertFalse(
            KindleStorefront.isAmazonWebsiteDataDomain("amazon.it.phish.example", for: italy)
        )

        let unitedKingdom = try XCTUnwrap(KindleStorefront.storefront(id: "uk"))
        XCTAssertTrue(
            KindleStorefront.isAmazonWebsiteDataDomain(
                "www.amazon.co.uk",
                for: unitedKingdom
            )
        )
        XCTAssertFalse(
            KindleStorefront.isAmazonWebsiteDataDomain(
                "www.amazon.com",
                for: unitedKingdom
            )
        )
    }

    func testLibraryBookRejectsUnknownOrSpoofedAbsoluteHostsEvenWithValidASIN() {
        let unsafeURLs = [
            "https://kindle.future.example/?asin=B012345678",
            "https://read.amazon.com.phish.example/?asin=B012345678",
            "http://read.amazon.com/?asin=B012345678",
            "https://user@read.amazon.com/?asin=B012345678",
            "https://read.amazon.com:444/?asin=B012345678",
        ]
        for rawURL in unsafeURLs {
            let book = makeBook(
                id: "B012345678",
                readerURL: rawURL,
                storefrontID: "us"
            )
            XCTAssertFalse(
                KindleBookValidator.isLikelyLibraryBook(book),
                "untrusted reader URL was accepted: \(rawURL)"
            )
        }

        XCTAssertTrue(
            KindleBookValidator.isLikelyLibraryBook(
                makeBook(
                    id: "B012345678",
                    readerURL: "B012345678",
                    storefrontID: "it"
                )
            ),
            "legacy ASIN-only records still migrate to the bound canonical host"
        )
        XCTAssertTrue(
            KindleBookValidator.isLikelyLibraryBook(
                makeBook(
                    id: "B012345678",
                    readerURL: "https://read.amazon.it/?asin=B012345678",
                    storefrontID: "it"
                )
            ),
            "a recognized legacy alias remains migratable"
        )

        let untrustedHostlessValues = [
            "/reader/B012345678",
            "reader/B012345678",
            "?asin=B012345678",
            "not a url B012345678",
            "https://%zz.example/reader/B012345678",
        ]
        for rawValue in untrustedHostlessValues {
            XCTAssertNil(
                KindleBookValidator.usableReaderURL(
                    rawValue,
                    storefront: KindleStorefront.entry(id: "it")
                ),
                "only an exact ASIN token may migrate without a trusted host: \(rawValue)"
            )
        }
    }

    func testExplicitBookStorefrontRepairsLegacyWrongStorefrontURL() {
        let book = makeBook(
            id: "B012345678",
            readerURL: "https://read.amazon.com/?asin=B012345678",
            lastReadURL: "https://read.amazon.com/?asin=B012345678",
            storefrontID: "es"
        )
        let expected = "https://leer.amazon.es/?asin=B012345678&ref_=kwl_kr_iv_rec_1"

        XCTAssertEqual(
            KindleBookValidator.repairedReaderURL(
                for: book,
                preferLastRead: false
            ),
            expected
        )
        XCTAssertEqual(
            KindleBookValidator.repairedReaderURL(
                for: book,
                preferLastRead: true
            ),
            expected
        )
        XCTAssertEqual(
            KindleBookValidator.usableReaderURL(
                "https://read.amazon.es/?asin=B012345678"
            ),
            expected,
            "without explicit ownership, the recognized URL host remains authoritative"
        )
    }

    func testShelfMergePrefersObservedHostOverDeclaredStorefront() {
        let mislabeledUSBook = makeBook(
            id: "B012345678",
            readerURL: "https://read.amazon.com/?asin=B012345678",
            storefrontID: "es"
        )
        XCTAssertFalse(
            KindleLibraryStore.isScrapedBook(
                mislabeledUSBook,
                compatibleWith: "es"
            ),
            "an observed US reader must not enter an ES-bound shelf"
        )
        XCTAssertTrue(
            KindleLibraryStore.isScrapedBook(
                mislabeledUSBook,
                compatibleWith: "us"
            )
        )

        let spanishAliasBook = makeBook(
            id: "B087654321",
            readerURL: "https://read.amazon.es/?asin=B087654321",
            storefrontID: "us"
        )
        XCTAssertTrue(
            KindleLibraryStore.isScrapedBook(
                spanishAliasBook,
                compatibleWith: "es"
            ),
            "a recognized alias host remains authoritative for its storefront"
        )
    }

    func testLegacyMigrationUsesReaderURLMajorityAndStableTieBreak() {
        let spanish = [
            makeBook(
                id: "es-1",
                readerURL: "https://leer.amazon.es/?asin=B000000001"
            ),
            makeBook(
                id: "es-2",
                readerURL: "https://read.amazon.es/?asin=B000000002"
            ),
            makeBook(
                id: "es-3",
                readerURL: "https://leer.amazon.es/?asin=B000000003",
                lastReadURL: "https://read.amazon.com/?asin=B000000003"
            ),
        ]
        let american = [
            makeBook(
                id: "us-1",
                readerURL: "https://read.amazon.com/?asin=B000000004"
            ),
            makeBook(
                id: "us-2",
                readerURL: "https://read.amazon.com/?asin=B000000005"
            ),
        ]
        XCTAssertEqual(
            KindleStorefront.inferredID(from: spanish + american),
            "es"
        )
        XCTAssertNil(KindleStorefront.inferredID(from: []))

        let tied = [
            makeBook(
                id: "us-tie",
                readerURL: "https://read.amazon.com/?asin=B000000006"
            ),
            makeBook(
                id: "es-tie",
                readerURL: "https://leer.amazon.es/?asin=B000000007"
            ),
        ]
        XCTAssertEqual(
            KindleStorefront.inferredID(from: tied),
            "us",
            "ties must follow canonical catalog order"
        )

        let explicitOwnership = makeBook(
            id: "owned",
            readerURL: "https://read.amazon.com/?asin=B000000008",
            storefrontID: "br"
        )
        XCTAssertEqual(KindleStorefront.inferredID(from: [explicitOwnership]), "br")

        let staleLastRead = makeBook(
            id: "stale-last-read",
            readerURL: "https://leer.amazon.es/?asin=B000000009",
            lastReadURL: "https://read.amazon.com/?asin=B000000009"
        )
        XCTAssertEqual(
            KindleStorefrontMigration.resolvedStorefront(for: staleLastRead)?.id,
            "es",
            "readerURL must outrank a lastReadURL rewritten by an older build"
        )
    }

    func testDomainDriftSentinelReturnsOnlyETLDPlusOne() {
        XCTAssertEqual(
            KindleDomainDriftSentinel.registrableDomainIfNeeded(
                rawURL: "https://reader.amazon.co.uk/path?asin=B012345678&secret=discard"
            ),
            "amazon.co.uk"
        )
        XCTAssertEqual(
            KindleDomainDriftSentinel.registrableDomainIfNeeded(
                rawURL: "https://reader.amazon.com.br/?asin=B012345678"
            ),
            "amazon.com.br"
        )
        XCTAssertEqual(
            KindleDomainDriftSentinel.registrableDomainIfNeeded(
                rawURL: "https://read.amazon.co.in/?asin=B012345678"
            ),
            "amazon.co.in"
        )
        XCTAssertEqual(
            KindleDomainDriftSentinel.registrableDomainIfNeeded(
                rawURL: "https://reader.amazon.co.za/?asin=B012345678"
            ),
            "amazon.co.za"
        )
        XCTAssertEqual(
            KindleDomainDriftSentinel.registrableDomainIfNeeded(
                rawURL: "https://read.amazon.com.phish.example/reader/B012345678"
            ),
            "phish.example",
            "an amazon-looking prefix must not escape the ordinary domain boundary"
        )
        XCTAssertEqual(
            KindleDomainDriftSentinel.registrableDomainIfNeeded(
                rawURL: "https://tenant.reader.books.example.co.in/reader/B012345678"
            ),
            "example.co.in"
        )
        XCTAssertEqual(
            KindleDomainDriftSentinel.registrableDomainIfNeeded(
                rawURL: "https://kindle.future.example/chapter?asin=B012345678"
            ),
            "future.example"
        )
        XCTAssertNil(
            KindleDomainDriftSentinel.registrableDomainIfNeeded(
                rawURL: "https://leer.amazon.es/?asin=B012345678"
            ),
            "known hosts are not drift"
        )
        XCTAssertNil(
            KindleDomainDriftSentinel.registrableDomainIfNeeded(
                rawURL: "https://kindle.future.example/no-asin"
            )
        )
        for unsafeURL in [
            "http://kindle.future.example/?asin=B012345678",
            "https://user@kindle.future.example/?asin=B012345678",
            "https://kindle.future.example:444/?asin=B012345678",
            "https://localhost/?asin=B012345678",
            "https://127.0.0.1/reader/B012345678",
        ] {
            XCTAssertNil(
                KindleDomainDriftSentinel.registrableDomainIfNeeded(
                    rawURL: unsafeURL
                ),
                "unsafe drift URL must not be emitted: \(unsafeURL)"
            )
        }
        let hint = KindleDomainDriftSentinel.registrableDomainIfNeeded(
            rawURL: "https://kindle.future.example/private/path?asin=B012345678&token=secret"
        )
        XCTAssertFalse(hint?.contains("/") == true)
        XCTAssertFalse(hint?.contains("?") == true)
        XCTAssertFalse(hint?.contains("token") == true)
    }

    func testEmptyShelfRequiresStableExplicitEvidence() {
        XCTAssertTrue(
            KindleEmptyShelfTrust.isTrusted(
                sawLibraryPage: true,
                sawAuthRequired: false,
                sawReaderPage: false,
                sawLibrarySignals: false,
                stableEmptyEvidencePasses: 2
            )
        )
        XCTAssertFalse(
            KindleEmptyShelfTrust.isTrusted(
                sawLibraryPage: true,
                sawAuthRequired: false,
                sawReaderPage: false,
                sawLibrarySignals: false,
                stableEmptyEvidencePasses: 1
            )
        )
        XCTAssertFalse(
            KindleEmptyShelfTrust.isTrusted(
                sawLibraryPage: true,
                sawAuthRequired: false,
                sawReaderPage: false,
                sawLibrarySignals: true,
                stableEmptyEvidencePasses: 3
            ),
            "selector drift must preserve the existing shelf"
        )
        XCTAssertFalse(
            KindleEmptyShelfTrust.isTrusted(
                sawLibraryPage: true,
                sawAuthRequired: true,
                sawReaderPage: false,
                sawLibrarySignals: false,
                stableEmptyEvidencePasses: 3
            )
        )
    }

    func testShelfScanFailureTaxonomyIsDeterministic() {
        XCTAssertEqual(
            KindleShelfScanFailureClassifier.code(
                sawLibraryPage: false,
                sawReaderPage: false,
                lastLanding: "other",
                pageReady: true,
                shelfLoading: false,
                atScrollEnd: true,
                stableSnapshotPasses: 2
            ),
            "library_path_lost"
        )
        XCTAssertEqual(
            KindleShelfScanFailureClassifier.code(
                sawLibraryPage: true,
                sawReaderPage: false,
                lastLanding: "library",
                pageReady: true,
                shelfLoading: false,
                atScrollEnd: true,
                stableSnapshotPasses: 1
            ),
            "DOM_changed"
        )
        XCTAssertEqual(
            KindleShelfScanFailureClassifier.code(
                sawLibraryPage: true,
                sawReaderPage: false,
                lastLanding: "library",
                pageReady: true,
                shelfLoading: true,
                atScrollEnd: false,
                stableSnapshotPasses: 0
            ),
            "scan_timeout"
        )
    }

    @MainActor
    func testScrapeLibraryRecognizesExplicitEmptyShelfAcrossSupportedStorefrontLanguages() async throws {
        let phrases = [
            "Your library is empty",
            "Tu biblioteca está vacía",
            "Sua biblioteca está vazia",
            "ライブラリに本がありません",
            "Deine Bibliothek ist leer",
            "Votre bibliothèque est vide",
            "La tua libreria è vuota",
            "Je bibliotheek is leeg",
            "आपकी लाइब्रेरी खाली है",
        ]
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        let baseURL = try XCTUnwrap(
            URL(string: "https://read.amazon.com/kindle-library")
        )

        for phrase in phrases {
            let escaped = phrase
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            webView.loadHTMLString(
                """
                <!doctype html>
                <html><head><style>
                [role=status] { display:block; width:320px; height:80px; }
                </style></head><body><main>
                <div role="status">\(escaped)</div>
                </main></body></html>
                """,
                baseURL: baseURL
            )
            try await waitUntilLoaded(webView)

            let raw = try await webView.evaluateJavaScript(
                KindleWebScripts.scrapeLibrary
            )
            let json = try XCTUnwrap(raw as? String)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8))
                    as? [String: Any]
            )
            XCTAssertEqual(object["pageReady"] as? Bool, true, phrase)
            XCTAssertEqual(object["hasReaderSignals"] as? Bool, false, phrase)
            XCTAssertEqual(object["hasEmptyShelfSignal"] as? Bool, true, phrase)
        }

        webView.loadHTMLString(
            """
            <!doctype html><html><head><style>
            input, [role=status] { display:block; width:320px; height:60px; }
            </style></head><body><main>
            <input type="search" value="filtered title">
            <div role="status">Your library is empty</div>
            </main></body></html>
            """,
            baseURL: baseURL
        )
        try await waitUntilLoaded(webView)
        let filteredRaw = try await webView.evaluateJavaScript(
            KindleWebScripts.scrapeLibrary
        )
        let filteredJSON = try XCTUnwrap(filteredRaw as? String)
        let filteredObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(filteredJSON.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(
            filteredObject["hasEmptyShelfSignal"] as? Bool,
            false,
            "an empty search result must never clear the cached shelf"
        )

        webView.loadHTMLString(
            """
            <!doctype html><html><head><style>
            main p { display:block; width:320px; height:60px; }
            </style></head><body><main>
            <p>If your library is empty, visit the Kindle Store to find your next book.</p>
            </main></body></html>
            """,
            baseURL: baseURL
        )
        try await waitUntilLoaded(webView)
        let helpRaw = try await webView.evaluateJavaScript(
            KindleWebScripts.scrapeLibrary
        )
        let helpJSON = try XCTUnwrap(helpRaw as? String)
        let helpObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(helpJSON.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(
            helpObject["hasEmptyShelfSignal"] as? Bool,
            false,
            "help copy containing an empty-shelf phrase must preserve cached books"
        )
    }

    @MainActor
    func testScrapeLibraryUnderstandsDutchShelfMetadataFallbacks() async throws {
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        webView.loadHTMLString(
            """
            <!doctype html><html><head><style>
            article { display:block; width:320px; height:180px; }
            img { display:block; width:80px; height:120px; }
            </style></head><body><main>
            <article role="listitem" data-asin="B012345678">
              <a href="https://lezen.amazon.nl/?asin=B012345678">
                <img alt="Een voorbeeldboek">
                <h2 data-testid="title">Een voorbeeldboek</h2>
              </a>
              <p class="author">door Voorbeeld Schrijver</p>
              <p>Laatst gelezen: 42</p>
            </article>
            </main></body></html>
            """,
            baseURL: try XCTUnwrap(
                URL(string: "https://lezen.amazon.nl/kindle-library")
            )
        )
        try await waitUntilLoaded(webView)

        let raw = try await webView.evaluateJavaScript(
            KindleWebScripts.scrapeLibrary
        )
        let json = try XCTUnwrap(raw as? String)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [String: Any]
        )
        let books = try XCTUnwrap(object["books"] as? [[String: Any]])
        let book = try XCTUnwrap(books.first)
        XCTAssertEqual(book["title"] as? String, "Een voorbeeldboek")
        XCTAssertEqual(book["author"] as? String, "Voorbeeld Schrijver")
        XCTAssertEqual(book["progressLabel"] as? String, "Laatst gelezen: 42")
        XCTAssertEqual(
            book["readerURL"] as? String,
            "https://lezen.amazon.nl/?asin=B012345678&ref_=kwl_kr_iv_rec_1"
        )
        XCTAssertEqual(object["shelfLoading"] as? Bool, false)
        XCTAssertEqual(object["atScrollEnd"] as? Bool, true, json)
        XCTAssertFalse((object["snapshotKey"] as? String ?? "").isEmpty)
    }

    @MainActor
    func testScrapeLibraryUnderstandsItalianShelfAndCanonicalizesAliasReader() async throws {
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        webView.loadHTMLString(
            """
            <!doctype html><html><head><style>
            article { display:block; width:320px; height:180px; }
            img { display:block; width:80px; height:120px; }
            </style></head><body><main>
            <article role="listitem" data-asin="B087654321">
              <a href="https://read.amazon.it/?asin=B087654321">
                <img alt="Il barone rampante">
                <h2 data-testid="title">Il barone rampante</h2>
              </a>
              <p class="author">di Italo Calvino</p>
              <p>Ultima lettura: 18</p>
            </article>
            </main></body></html>
            """,
            baseURL: try XCTUnwrap(
                URL(string: "https://leggi.amazon.it/kindle-library")
            )
        )
        try await waitUntilLoaded(webView)

        let raw = try await webView.evaluateJavaScript(
            KindleWebScripts.scrapeLibrary
        )
        let json = try XCTUnwrap(raw as? String)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [String: Any]
        )
        let books = try XCTUnwrap(object["books"] as? [[String: Any]])
        let book = try XCTUnwrap(books.first)
        XCTAssertEqual(book["title"] as? String, "Il barone rampante")
        XCTAssertEqual(book["author"] as? String, "Italo Calvino")
        XCTAssertEqual(book["progressLabel"] as? String, "Ultima lettura: 18")
        XCTAssertEqual(
            book["readerURL"] as? String,
            "https://leggi.amazon.it/?asin=B087654321&ref_=kwl_kr_iv_rec_1"
        )
        XCTAssertEqual(object["authRequired"] as? Bool, false)
        XCTAssertEqual(object["shelfLoading"] as? Bool, false)
        XCTAssertEqual(object["atScrollEnd"] as? Bool, true, json)
    }

    @MainActor
    func testScrapeLibraryRecognizesAmazonChallengeWithoutCredentialInputs() async throws {
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        webView.loadHTMLString(
            "<!doctype html><html><body><main>Verifica richiesta</main></body></html>",
            baseURL: try XCTUnwrap(URL(string: "https://www.amazon.it/ap/cvf"))
        )
        try await waitUntilLoaded(webView)

        let raw = try await webView.evaluateJavaScript(
            KindleWebScripts.scrapeLibrary
        )
        let json = try XCTUnwrap(raw as? String)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(object["authRequired"] as? Bool, true)
        XCTAssertEqual(object["authState"] as? String, "challenge")
        XCTAssertEqual(object["hasEmptyShelfSignal"] as? Bool, false)
    }

    @MainActor
    func testItalianAndDutchReaderControlFallbacks() async throws {
        let fixtures: [(String, [String: String])] = [
            ("it", [
                "next": "Pagina successiva",
                "previous": "Pagina precedente",
                "settings": "Impostazioni di lettura",
                "font-size": "Dimensione carattere",
                "single-column": "Colonna singola",
                "narrow": "Stretto",
                "toc": "Indice",
                "close": "Chiudi",
                "yes": "Continua",
                "no": "Annulla",
                "location": "Posizione 42",
                "sync-dialog": "Ultima posizione letta",
            ]),
            ("nl", [
                "next": "Volgende pagina",
                "previous": "Vorige pagina",
                "settings": "Leesinstellingen",
                "font-size": "Lettergrootte",
                "single-column": "Eén kolom",
                "narrow": "Smal",
                "toc": "Inhoudsopgave",
                "close": "Sluiten",
                "yes": "Doorgaan",
                "no": "Annuleren",
                "location": "Locatie 42",
                "sync-dialog": "Meest recent gelezen locatie",
            ]),
        ]

        for (storefrontID, labels) in fixtures {
            let controls = labels.map { kind, label in
                "<button data-cr-kindle-kind=\"\(kind)\">\(label)</button>"
            }.joined()
            let webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
            webView.loadHTMLString(
                "<!doctype html><html><body>\(controls)</body></html>",
                baseURL: try XCTUnwrap(
                    KindleStorefront.entry(id: storefrontID)?.readerURL(
                        asin: "B012345678"
                    )
                )
            )
            try await waitUntilLoaded(webView)

            let raw = try await webView.evaluateJavaScript(
                KindleWebScripts.readerSemanticFixtureProbe
            )
            let json = try XCTUnwrap(raw as? String)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8))
                    as? [String: Any]
            )
            let matches = try XCTUnwrap(object["matches"] as? [String: Bool])
            XCTAssertEqual(matches.count, labels.count, storefrontID)
            for kind in labels.keys {
                XCTAssertEqual(matches[kind], true, "\(storefrontID):\(kind)")
            }
        }
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    @MainActor
    private func waitUntilLoaded(_ webView: WKWebView) async throws {
        for _ in 0..<80 {
            let ready = try? await webView.evaluateJavaScript(
                "document.readyState"
            ) as? String
            if !webView.isLoading, ready == "complete" {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("WKWebView fixture did not finish loading")
    }

    private func makeBook(
        id: String,
        readerURL: String,
        lastReadURL: String? = nil,
        storefrontID: String? = nil
    ) -> KindleBook {
        KindleBook(
            id: id,
            asin: nil,
            title: id,
            author: "",
            coverURL: nil,
            readerURL: readerURL,
            progressLabel: "",
            storefrontID: storefrontID,
            language: nil,
            languageSource: nil,
            kindleWritingMode: nil,
            kindleReadingDirection: nil,
            kindlePageProgressionDirection: nil,
            lastOpenedAt: nil,
            lastSyncedAt: Date(timeIntervalSince1970: 0),
            lastReadPageKey: nil,
            lastReadURL: lastReadURL
        )
    }
}
