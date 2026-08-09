//
//  KindleStorefront.swift
//  CastReader
//
//  Amazon marketplace is an account property. App language and device region
//  only rank candidates; the user's explicit selection remains authoritative.
//

import Foundation

struct KindleStorefront: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let marketplaceRegion: String
    let canonicalHost: String
    let aliasHosts: [String]
    let displayName: String
    let entryEnabled: Bool
    let entryDisabledReason: String?

    var isSelectable: Bool { entryEnabled }

    var flag: String {
        marketplaceRegion.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            return UnicodeScalar(127397 + scalar.value)
        }.map(String.init).joined()
    }

    var libraryURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = canonicalHost
        components.path = KindleStorefrontCatalog.shared.paths.library
        return components.url!
    }

    func readerURL(asin: String) -> URL {
        let normalizedASIN = asin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var components = URLComponents()
        components.scheme = "https"
        components.host = canonicalHost
        components.path = KindleStorefrontCatalog.shared.paths.reader
        components.queryItems = [
            URLQueryItem(name: "asin", value: normalizedASIN),
            URLQueryItem(name: "ref_", value: KindleStorefront.readerReferenceValue)
        ]
        return components.url!
    }

    var label: String {
        "\(flag) \(displayName)"
    }

    var recognizedHosts: [String] {
        [canonicalHost] + aliasHosts
    }

    func matches(host: String?) -> Bool {
        guard let normalized = Self.normalizedHost(host) else { return false }
        return recognizedHosts.contains(normalized)
    }

    static var all: [KindleStorefront] {
        KindleStorefrontCatalog.shared.storefronts
    }

    static var selectable: [KindleStorefront] {
        all.filter(\.entryEnabled)
    }

    static var us: KindleStorefront {
        storefront(id: KindleStorefrontCatalog.shared.fallbackStorefrontID)
            ?? all.first!
    }

    static func storefront(id: String?) -> KindleStorefront? {
        guard let id else { return nil }
        return KindleStorefrontCatalog.shared.byID[id.lowercased()]
    }

    /// Returns a storefront ID that is enabled for new navigation. URL
    /// destinations still have to pass `KindleStorefrontNavigationPolicy`:
    /// aliases may identify this enabled storefront for migration, but only its
    /// canonical host may be loaded as a fresh destination.
    static func entry(id: String?) -> KindleStorefront? {
        storefront(id: id).flatMap { $0.entryEnabled ? $0 : nil }
    }

    static func storefront(host: String?) -> KindleStorefront? {
        guard let host = normalizedHost(host) else { return nil }
        return KindleStorefrontCatalog.shared.byHost[host]
    }

    static func storefront(url: URL?) -> KindleStorefront? {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else {
            return nil
        }
        return storefront(host: url.host)
    }

    static func entry(url: URL?) -> KindleStorefront? {
        storefront(url: url).flatMap { $0.entryEnabled ? $0 : nil }
    }

    /// Exact canonical ownership check for fresh navigation. Recognition via
    /// `storefront(url:)` / `entry(url:)` deliberately remains broader so the
    /// seven historical `read.amazon.*` aliases can still be migrated without
    /// ever becoming a new shelf or reader entry.
    func ownsCanonicalURL(_ url: URL?) -> Bool {
        guard let url,
              Self.storefront(url: url)?.id == id,
              let host = Self.normalizedHost(url.host) else {
            return false
        }
        return host == canonicalHost
    }

    static func storefront(rawURL: String?) -> KindleStorefront? {
        guard let rawURL,
              rawURL == rawURL.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL) else {
            return nil
        }
        return storefront(url: url)
    }

    static func entry(rawURL: String?) -> KindleStorefront? {
        storefront(rawURL: rawURL).flatMap { $0.entryEnabled ? $0 : nil }
    }

    static func matches(host: String?) -> Bool {
        storefront(host: host) != nil
    }

    static func matches(url: URL?) -> Bool {
        storefront(url: url) != nil
    }

    static func suggested(
        deviceRegion: String?,
        appLanguage: AppLanguage
    ) -> KindleStorefront {
        orderedCandidates(deviceRegion: deviceRegion, appLanguage: appLanguage).first ?? us
    }

    static func suggested(
        deviceRegion: String?,
        appLanguage: String?
    ) -> KindleStorefront {
        orderedCandidates(deviceRegion: deviceRegion, languageCode: appLanguage).first ?? us
    }

    static func orderedCandidates(
        deviceRegion: String?,
        appLanguage: AppLanguage
    ) -> [KindleStorefront] {
        orderedCandidates(
            deviceRegion: deviceRegion,
            languageCode: languageCode(for: appLanguage)
        )
    }

    static func orderedCandidates(
        deviceRegion: String?,
        languageCode: String?
    ) -> [KindleStorefront] {
        let catalog = KindleStorefrontCatalog.shared
        var orderedIDs: [String] = []

        if let region = deviceRegion?.uppercased(),
           let regionID = catalog.regionToStorefront[region] {
            orderedIDs.append(regionID)
        }

        let normalizedLanguage = normalizedLanguageCode(languageCode)
        orderedIDs.append(contentsOf: catalog.languageCandidateOrder[normalizedLanguage] ?? [])
        orderedIDs.append(contentsOf: catalog.storefronts.filter(\.entryEnabled).map(\.id))

        var seen = Set<String>()
        return orderedIDs.compactMap { id in
            guard seen.insert(id).inserted,
                  let storefront = catalog.byID[id],
                  storefront.entryEnabled else {
                return nil
            }
            return storefront
        }
    }

    static func orderedCandidates(
        deviceRegion: String?,
        appLanguage: String?
    ) -> [KindleStorefront] {
        orderedCandidates(deviceRegion: deviceRegion, languageCode: appLanguage)
    }

    static var recognizedHostsJavaScriptArray: String {
        let hosts = all.flatMap(\.recognizedHosts)
        guard let data = try? JSONSerialization.data(withJSONObject: hosts),
              let value = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return value
    }

    static var javaScriptHostArray: String {
        recognizedHostsJavaScriptArray
    }

    static var javaScriptCanonicalHostMap: String {
        let fallbackHost = KindleStorefront.us.canonicalHost
        let aliases = Dictionary(uniqueKeysWithValues: all.flatMap { storefront in
            let navigationHost = storefront.entryEnabled
                ? storefront.canonicalHost
                : fallbackHost
            return storefront.recognizedHosts.map { ($0, navigationHost) }
        })
        guard let data = try? JSONSerialization.data(withJSONObject: aliases),
              let value = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return value
    }

    static var readerReferenceValue: String {
        KindleStorefrontCatalog.shared.readerRef
    }

    static func isAmazonWebsiteDataDomain(_ raw: String) -> Bool {
        var domain = raw.lowercased()
        if domain.hasPrefix(".") {
            domain.removeFirst()
        }
        guard !domain.isEmpty else { return false }
        return amazonMarketplaceDomains.contains { marketplaceDomain in
            domain == marketplaceDomain || domain.hasSuffix(".\(marketplaceDomain)")
        }
    }

    /// WKWebsiteDataRecord exposes only a display domain. Scope forced
    /// reauthentication to the active marketplace so an expired Italian Kindle
    /// session cannot sign the user out of an otherwise valid US/UK account.
    static func isAmazonWebsiteDataDomain(
        _ raw: String,
        for storefront: KindleStorefront
    ) -> Bool {
        var domain = raw.lowercased()
        if domain.hasPrefix(".") {
            domain.removeFirst()
        }
        guard isAmazonWebsiteDataDomain(domain),
              let observed = registrableDomain(for: domain),
              let expected = registrableDomain(for: storefront.canonicalHost) else {
            return false
        }
        return observed == expected
    }

    static func registrableDomain(for host: String?) -> String? {
        guard let host = normalizedHost(host) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard host.count <= 253,
              labels.count >= 2,
              labels.allSatisfy({
                  !$0.isEmpty
                      && $0.count <= 63
                      && $0.range(
                          of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#,
                          options: .regularExpression
                      ) != nil
              }),
              host.range(
                  of: #"^\d+(?:\.\d+){3}$"#,
                  options: .regularExpression
              ) == nil else {
            return nil
        }

        let commonSecondLevelCCTLDLabels: Set<String> = [
            "ac", "co", "com", "edu", "go", "gov", "ne", "net", "or", "org"
        ]
        let hasCommonSecondLevelCCTLD = labels.last?.count == 2
            && labels.dropLast().last.map(commonSecondLevelCCTLDLabels.contains) == true
        let registrableLabelCount = hasCommonSecondLevelCCTLD ? 3 : 2
        guard labels.count >= registrableLabelCount else { return nil }

        // Preserve the Amazon-owned boundary only when `amazon` immediately
        // precedes the inferred public suffix. A spoof such as
        // read.amazon.com.phish.example must collapse to phish.example.
        if let amazonIndex = labels.lastIndex(of: "amazon"),
           amazonIndex == labels.count - registrableLabelCount {
            return labels[amazonIndex...].joined(separator: ".")
        }
        return labels.suffix(registrableLabelCount).joined(separator: ".")
    }

    static func registrableDomainHint(host: String?) -> String? {
        registrableDomain(for: host)
    }

    private static func normalizedHost(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.contains(where: \.isWhitespace) else {
            return nil
        }
        var host = raw.lowercased()
        if host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty, !host.hasSuffix(".") else { return nil }
        return host
    }

    private static func languageCode(for appLanguage: AppLanguage) -> String? {
        switch appLanguage {
        case .system:
            return Locale.autoupdatingCurrent.language.languageCode?.identifier
        default:
            return appLanguage.rawValue
        }
    }

    private static func normalizedLanguageCode(_ raw: String?) -> String {
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased() ?? ""
        if normalized == "pt" || normalized.hasPrefix("pt-") {
            return "pt-BR"
        }
        return normalized.split(separator: "-").first.map(String.init) ?? ""
    }

    private static var amazonMarketplaceDomains: Set<String> {
        Set(all.compactMap { storefront in
            let labels = storefront.canonicalHost.split(separator: ".").map(String.init)
            guard labels.count > 2 else { return storefront.canonicalHost }
            return labels.dropFirst().joined(separator: ".")
        })
    }
}

/// Stable, injectable environment signals for first-use storefront ranking.
/// Keeping Foundation's live Locale/TimeZone values outside the scorer makes
/// recommendation behavior deterministic in tests and across view redraws.
struct KindleStorefrontRecommendationContext: Equatable, Sendable {
    let regionCode: String?
    let preferredLanguages: [String]
    let appLanguageCode: String?
    let timeZoneIdentifier: String?
    let secondsFromGMT: Int?

    init(
        regionCode: String?,
        preferredLanguages: [String],
        appLanguageCode: String?,
        timeZoneIdentifier: String?,
        secondsFromGMT: Int?
    ) {
        self.regionCode = regionCode
        self.preferredLanguages = preferredLanguages
        self.appLanguageCode = appLanguageCode
        self.timeZoneIdentifier = timeZoneIdentifier
        self.secondsFromGMT = secondsFromGMT
    }

    init(
        locale: Locale,
        preferredLanguages: [String],
        appLanguageCode: String?,
        timeZone: TimeZone,
        date: Date = Date()
    ) {
        self.init(
            regionCode: locale.region?.identifier,
            preferredLanguages: preferredLanguages,
            appLanguageCode: appLanguageCode,
            timeZoneIdentifier: timeZone.identifier,
            secondsFromGMT: timeZone.secondsFromGMT(for: date)
        )
    }
}

struct KindleStorefrontRecommendation: Equatable, Sendable {
    let recommended: KindleStorefront
    let candidates: [KindleStorefront]
}

/// Combines independent locale signals instead of assuming that interface
/// language alone identifies the marketplace where a Kindle account buys books.
/// An established or explicitly persisted binding remains authoritative; the
/// default `.us` placeholder on a fresh install must not be passed as one.
enum KindleStorefrontRecommender {
    static func recommend(
        context: KindleStorefrontRecommendationContext,
        authoritativeBoundStorefrontID: String? = nil
    ) -> KindleStorefrontRecommendation {
        let selectable = KindleStorefront.selectable
        let catalogOrder = Dictionary(
            uniqueKeysWithValues: selectable.enumerated().map { ($1.id, $0) }
        )
        var scores = Dictionary(uniqueKeysWithValues: selectable.map { ($0.id, 0) })

        func add(_ storefrontID: String?, _ score: Int) {
            guard let storefront = KindleStorefront.entry(id: storefrontID) else { return }
            scores[storefront.id, default: 0] += score
        }

        // Device region is the clearest non-account signal.
        add(storefrontID(forRegionCode: context.regionCode), 10_000)

        // A user-selected interface language is intentional, while an explicit
        // region subtag (for example en-GB or es-MX) is stronger than its base
        // language's generic candidate list.
        add(languageRegionStorefrontID(context.appLanguageCode), 5_000)
        addLanguageOrder(context.appLanguageCode, baseScore: 2_400, add: add)

        // Preferred languages retain their order. Multiple signals may reinforce
        // the same storefront, which is useful for bilingual users living abroad.
        for (index, language) in context.preferredLanguages.enumerated() {
            let decay = min(index, 8)
            add(languageRegionStorefrontID(language), 4_200 - decay * 260)
            addLanguageOrder(
                language,
                baseScore: 1_800 - decay * 160,
                add: add
            )
        }

        // IANA city identifiers are considerably safer than offsets. Offsets are
        // deliberately weak and only break ties or provide a last-resort hint.
        for (index, id) in storefrontIDs(forTimeZoneIdentifier: context.timeZoneIdentifier).enumerated() {
            add(id, 1_400 - index * 80)
        }
        for (index, id) in storefrontIDs(forSecondsFromGMT: context.secondsFromGMT).enumerated() {
            add(id, 360 - index * 20)
        }

        let ranked = selectable.sorted { lhs, rhs in
            let lhsScore = scores[lhs.id, default: 0]
            let rhsScore = scores[rhs.id, default: 0]
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return catalogOrder[lhs.id, default: .max]
                < catalogOrder[rhs.id, default: .max]
        }

        var candidates: [KindleStorefront] = []
        if let bound = KindleStorefront.entry(id: authoritativeBoundStorefrontID) {
            candidates.append(bound)
        }
        candidates.append(contentsOf: ranked)

        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.id).inserted }
        let recommended = candidates.first ?? KindleStorefront.us
        return KindleStorefrontRecommendation(
            recommended: recommended,
            candidates: candidates
        )
    }

    private static func addLanguageOrder(
        _ languageCode: String?,
        baseScore: Int,
        add: (String?, Int) -> Void
    ) {
        guard baseScore > 0 else { return }
        let ids = KindleStorefront.orderedCandidates(
            deviceRegion: nil,
            languageCode: languageCode
        ).map(\.id)
        let preferredCount = preferredCandidateCount(for: languageCode)
        for (index, id) in ids.prefix(preferredCount).enumerated() {
            add(id, max(80, baseScore - index * 180))
        }
    }

    /// `orderedCandidates` intentionally appends the full catalog. This count
    /// limits scoring to the language-specific prefix without duplicating the
    /// shared contract in the UI or the recommendation engine.
    private static func preferredCandidateCount(for languageCode: String?) -> Int {
        switch normalizedLanguageCode(languageCode) {
        case "en": return 5
        case "es": return 3
        case "pt-BR", "ja", "de", "fr", "it", "hi": return 2
        default: return 0
        }
    }

    private static func normalizedLanguageCode(_ raw: String?) -> String {
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased() ?? ""
        if normalized == "pt" || normalized.hasPrefix("pt-") {
            return "pt-BR"
        }
        return normalized.split(separator: "-").first.map(String.init) ?? ""
    }

    private static func storefrontID(forRegionCode raw: String?) -> String? {
        guard let raw else { return nil }
        let region = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let mapping: [String: String] = [
            "US": "us", "GB": "uk", "UK": "uk", "CA": "ca", "AU": "au",
            "JP": "jp", "DE": "de", "FR": "fr", "IT": "it", "ES": "es",
            "IN": "in", "BR": "br", "MX": "mx", "NL": "nl",
        ]
        return mapping[region]
    }

    private static func languageRegionStorefrontID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
        guard parts.count > 1 else { return nil }
        // Script subtags have four letters; region subtags have two letters or
        // three digits. Only an explicit region is evidence.
        let region = parts.dropFirst().first { part in
            (part.count == 2 && part.allSatisfy(\.isLetter))
                || (part.count == 3 && part.allSatisfy(\.isNumber))
        }
        return storefrontID(forRegionCode: region)
    }

    private static func storefrontIDs(forTimeZoneIdentifier raw: String?) -> [String] {
        guard let raw else { return [] }
        let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !identifier.isEmpty else { return [] }

        if identifier.hasPrefix("australia/") { return ["au"] }
        if identifier.hasPrefix("us/") { return ["us"] }
        if identifier.hasPrefix("canada/") { return ["ca"] }
        if identifier.hasPrefix("mexico/") { return ["mx"] }
        if identifier.hasPrefix("brazil/") { return ["br"] }

        // Kindle China is closed. For Chinese-speaking East Asian time zones,
        // keep the enabled global storefront first, then surface the two nearby
        // English/Japanese catalogs instead of falling back to US/UK/CA solely
        // because that is the static catalog order.
        let eastAsiaFallbackZones: Set<String> = [
            "asia/shanghai", "asia/hong_kong", "asia/taipei",
            "asia/singapore", "asia/macau", "asia/macao",
        ]
        if eastAsiaFallbackZones.contains(identifier) {
            return ["us", "jp", "au"]
        }

        let exact: [String: String] = [
            "asia/tokyo": "jp", "japan": "jp",
            "asia/kolkata": "in", "asia/calcutta": "in",
            "europe/london": "uk", "europe/belfast": "uk", "gb": "uk", "gb-eire": "uk",
            "europe/berlin": "de", "europe/busingen": "de",
            "europe/paris": "fr", "europe/monaco": "fr",
            "europe/rome": "it", "europe/san_marino": "it", "europe/vatican": "it",
            "europe/madrid": "es", "europe/ceuta": "es", "atlantic/canary": "es",
            "europe/amsterdam": "nl",
            "america/sao_paulo": "br", "america/bahia": "br", "america/belem": "br",
            "america/fortaleza": "br", "america/manaus": "br", "america/recife": "br",
            "america/rio_branco": "br",
            "america/mexico_city": "mx", "america/cancun": "mx", "america/chihuahua": "mx",
            "america/monterrey": "mx", "america/tijuana": "mx", "america/merida": "mx",
            "america/toronto": "ca", "america/vancouver": "ca", "america/edmonton": "ca",
            "america/winnipeg": "ca", "america/halifax": "ca", "america/st_johns": "ca",
            "america/new_york": "us", "america/chicago": "us", "america/denver": "us",
            "america/los_angeles": "us", "america/phoenix": "us", "america/anchorage": "us",
            "pacific/honolulu": "us",
        ]
        return exact[identifier].map { [$0] } ?? []
    }

    private static func storefrontIDs(forSecondsFromGMT seconds: Int?) -> [String] {
        guard let seconds else { return [] }
        switch seconds {
        case 19_800: return ["in"]
        case 32_400: return ["jp"]
        case 34_200, 37_800, 36_000, 39_600: return ["au"]
        case -12_600: return ["ca"]
        case -10_800, -7_200: return ["br"]
        case 0: return ["uk"]
        case 3_600, 7_200: return ["de", "fr", "it", "es", "nl"]
        case -28_800, -25_200, -21_600, -18_000, -14_400:
            return ["us", "ca", "mx"]
        default: return []
        }
    }
}

enum KindleStorefrontMigration {
    /// One precedence rule for every legacy migration path. The shelf URL is
    /// the book's stable ownership signal; `lastReadURL` may have been rewritten
    /// by older builds and therefore only acts as a final fallback.
    static func resolvedStorefront(for book: KindleBook) -> KindleStorefront? {
        KindleStorefront.storefront(id: book.storefrontID)
            ?? KindleStorefront.storefront(rawURL: book.readerURL)
            ?? KindleStorefront.storefront(rawURL: book.lastReadURL)
    }

    static func inferredStorefrontID(from books: [KindleBook]) -> String? {
        var votes: [String: Int] = [:]
        for book in books {
            if let storefront = resolvedStorefront(for: book) {
                votes[storefront.id, default: 0] += 1
            }
        }
        guard let maximum = votes.values.max() else { return nil }
        return KindleStorefront.all
            .map(\.id)
            .first { votes[$0] == maximum }
    }
}

extension KindleStorefront {
    static func inferredID(from books: [KindleBook]) -> String? {
        KindleStorefrontMigration.inferredStorefrontID(from: books)
    }
}

enum KindleDomainDriftSentinel {
    static func registrableDomainIfNeeded(rawURL: String) -> String? {
        guard rawURL == rawURL.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host,
              host.split(separator: ".").count >= 2,
              KindleBookValidator.containsASIN(rawURL),
              !KindleStorefront.matches(host: host) else {
            return nil
        }
        return KindleStorefront.registrableDomain(for: host)
    }
}

enum KindleStorefrontNavigationPolicy {
    /// Recognition is intentionally broader than navigation. A destination is
    /// safe only when it is the canonical host of the expected active
    /// marketplace; this keeps aliases, historical CN links and cross-site
    /// redirects observable without allowing them into a fresh session.
    static func allows(_ url: URL?, expectedStorefrontID: String?) -> Bool {
        guard let expected = KindleStorefront.entry(id: expectedStorefrontID) else {
            return false
        }
        return expected.ownsCanonicalURL(url)
    }

    /// Main-frame navigation is deny-by-default. Besides the active Kindle
    /// storefront, the only exception is a secure Amazon-owned authentication
    /// endpoint needed to recover an expired reader session.
    static func allowsMainFrame(
        _ url: URL?,
        expectedStorefrontID: String?,
        expectedAuthenticationReturnPath: String? = nil
    ) -> Bool {
        // A recognized Kindle host is always governed by storefront ownership,
        // even when its path resembles an auth endpoint. This prevents another
        // marketplace (and recognition-only CN) from using `/ap/signin` as an
        // authentication-exception bypass.
        if KindleStorefront.storefront(url: url) != nil {
            return allows(url, expectedStorefrontID: expectedStorefrontID)
        }
        return isSafeAmazonAuthenticationURL(
            url,
            expectedStorefrontID: expectedStorefrontID,
            expectedReturnPath: expectedAuthenticationReturnPath
        )
    }

    /// Reader navigation is stricter than ordinary storefront navigation. A
    /// canonical host alone is not enough: the destination must remain the
    /// current book's exact reader entry, including both ASIN and the contract
    /// `ref_` identity. Amazon sign-in URLs are accepted only inside the same
    /// marketplace, and every nested return target is checked by this same
    /// policy before the main frame may follow it.
    static func allowsMainFrame(
        _ url: URL?,
        expectedStorefrontID: String?,
        expectedASIN: String,
        expectedReaderRef: String = KindleStorefront.readerReferenceValue
    ) -> Bool {
        allowsReaderMainFrame(
            url,
            expectedStorefrontID: expectedStorefrontID,
            expectedASIN: expectedASIN,
            expectedReaderRef: expectedReaderRef
        )
    }

    static func allowsReaderMainFrame(
        _ url: URL?,
        expectedStorefrontID: String?,
        expectedASIN: String,
        expectedReaderRef: String = KindleStorefront.readerReferenceValue
    ) -> Bool {
        guard let expected = KindleStorefront.entry(id: expectedStorefrontID),
              let asin = normalizedASIN(expectedASIN),
              expectedReaderRef == expectedReaderRef.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !expectedReaderRef.isEmpty else {
            return false
        }
        return allowsReaderMainFrame(
            url,
            expectedStorefront: expected,
            expectedASIN: asin,
            expectedReaderRef: expectedReaderRef,
            authenticationDepth: 0,
            visitedURLs: []
        )
    }

    static func isExactReaderURL(
        _ url: URL?,
        expectedStorefrontID: String?,
        expectedASIN: String,
        expectedReaderRef: String = KindleStorefront.readerReferenceValue
    ) -> Bool {
        guard let expected = KindleStorefront.entry(id: expectedStorefrontID),
              let url,
              let asin = normalizedASIN(expectedASIN),
              expectedReaderRef == expectedReaderRef.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !expectedReaderRef.isEmpty,
              expected.ownsCanonicalURL(url) else {
            return false
        }

        let expectedPath = expected.readerURL(asin: asin).path
        let observedPath = url.path.isEmpty ? "/" : url.path
        guard observedPath == expectedPath,
              let queryItems = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              )?.queryItems else {
            return false
        }

        let asinItems = queryItems.filter { $0.name.lowercased() == "asin" }
        let refItems = queryItems.filter { $0.name.lowercased() == "ref_" }
        guard asinItems.count == 1,
              refItems.count == 1,
              asinItems[0].name == "asin",
              refItems[0].name == "ref_",
              let rawObservedASIN = asinItems[0].value,
              rawObservedASIN == rawObservedASIN.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              let observedASIN = normalizedASIN(rawObservedASIN),
              observedASIN == asin,
              refItems[0].value == expectedReaderRef else {
            return false
        }
        return true
    }

    static func isSafeAmazonAuthenticationURL(
        _ url: URL?,
        expectedStorefrontID: String? = nil,
        expectedReturnPath: String? = nil
    ) -> Bool {
        isSafeAmazonAuthenticationURL(
            url,
            expectedStorefrontID: expectedStorefrontID,
            expectedReturnPath: expectedReturnPath,
            authenticationDepth: 0,
            visitedURLs: []
        )
    }

    private static func isSafeAmazonAuthenticationURL(
        _ url: URL?,
        expectedStorefrontID: String?,
        expectedReturnPath: String?,
        authenticationDepth: Int,
        visitedURLs: Set<String>
    ) -> Bool {
        guard let url,
              authenticationDepth <= 8,
              !visitedURLs.contains(url.absoluteString),
              isSafeAmazonAuthenticationEnvelope(
                  url,
                  expectedStorefrontID: expectedStorefrontID
              ) else {
            return false
        }

        if let expectedStorefrontID {
            guard let expected = KindleStorefront.entry(id: expectedStorefrontID) else {
                return false
            }
            var nextVisitedURLs = visitedURLs
            nextVisitedURLs.insert(url.absoluteString)

            let returnTargets = (URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []).filter {
                let name = $0.name.lowercased()
                return name == "openid.return_to" || name == "return_to"
            }
            if returnTargets.isEmpty {
                // Amazon's email-first sign-in advances by form POSTs to
                // /ap/signin whose openid parameters travel in the request
                // body, which WKWebView cannot observe. The envelope above
                // already pins HTTPS and the expected marketplace domain, and
                // the post-authentication redirect re-enters this policy as
                // its own navigation. Android ships the same semantics.
                return true
            }
            for item in returnTargets {
                guard let rawTarget = item.value,
                      let target = URL(string: rawTarget) else {
                    return false
                }
                // Live evidence 2026-08-09: /ap/cvf/transactionapproval points
                // its return_to at the next auth step (back to /ap/signin),
                // not at the shelf. A nested same-marketplace auth envelope is
                // therefore as acceptable as the direct canonical shelf
                // return, mirroring the reader policy's recursion. Depth and
                // cycle guards keep redirect loops fail-closed.
                let directShelfReturn = allows(
                    target,
                    expectedStorefrontID: expected.id
                ) && (expectedReturnPath.map({
                    normalizedPath(target.path) == normalizedPath($0)
                }) ?? true)
                let nestedAuthenticationStep = isSafeAmazonAuthenticationURL(
                    target,
                    expectedStorefrontID: expectedStorefrontID,
                    expectedReturnPath: expectedReturnPath,
                    authenticationDepth: authenticationDepth + 1,
                    visitedURLs: nextVisitedURLs
                )
                guard directShelfReturn || nestedAuthenticationStep else {
                    return false
                }
            }
        }

        return true
    }

    private static func allowsReaderMainFrame(
        _ url: URL?,
        expectedStorefront: KindleStorefront,
        expectedASIN: String,
        expectedReaderRef: String,
        authenticationDepth: Int,
        visitedURLs: Set<String>
    ) -> Bool {
        guard let url,
              authenticationDepth <= 8,
              !visitedURLs.contains(url.absoluteString) else {
            return false
        }
        var nextVisitedURLs = visitedURLs
        nextVisitedURLs.insert(url.absoluteString)

        // A recognized Kindle destination never receives the authentication
        // exception. This rejects aliases, CN, another marketplace, the bare
        // root, library/landing routes, and reader URLs with incomplete or
        // conflicting identity.
        if KindleStorefront.storefront(url: url) != nil {
            return isExactReaderURL(
                url,
                expectedStorefrontID: expectedStorefront.id,
                expectedASIN: expectedASIN,
                expectedReaderRef: expectedReaderRef
            )
        }

        guard isSafeAmazonAuthenticationEnvelope(
            url,
            expectedStorefrontID: expectedStorefront.id
        ), let returnTargets = authenticationReturnTargets(in: url) else {
            return false
        }

        // Sign-in steps legitimately omit return_to: Amazon's email-first flow
        // advances by form POSTs to /ap/signin with the openid parameters in
        // the request body, which WKWebView cannot observe. Allowing the step
        // never surrenders the book identity — whatever URL Amazon redirects
        // to afterwards re-enters this policy as its own main-frame navigation
        // and must still be the exact reader entry. Matches Android.
        if returnTargets.isEmpty {
            return true
        }

        // Every target (including nested auth URLs) must preserve the same book
        // identity.
        return returnTargets.allSatisfy { target in
            allowsReaderMainFrame(
                target,
                expectedStorefront: expectedStorefront,
                expectedASIN: expectedASIN,
                expectedReaderRef: expectedReaderRef,
                authenticationDepth: authenticationDepth + 1,
                visitedURLs: nextVisitedURLs
            )
        }
    }

    private static func isSafeAmazonAuthenticationEnvelope(
        _ url: URL,
        expectedStorefrontID: String?
    ) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              resemblesAmazonAuthenticationURL(url) else {
            return false
        }
        guard let expectedStorefrontID else { return true }
        guard let expected = KindleStorefront.entry(id: expectedStorefrontID) else {
            return false
        }
        return KindleStorefront.isAmazonWebsiteDataDomain(
            url.host ?? "",
            for: expected
        )
    }

    private static func authenticationReturnTargets(in url: URL) -> [URL]? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        let items = (components.queryItems ?? []).filter {
            let name = $0.name.lowercased()
            return name == "openid.return_to" || name == "return_to"
        }
        var targets: [URL] = []
        targets.reserveCapacity(items.count)
        for item in items {
            guard let rawTarget = item.value,
                  rawTarget == rawTarget.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ),
                  !rawTarget.isEmpty,
                  let target = URL(string: rawTarget) else {
                return nil
            }
            targets.append(target)
        }
        return targets
    }

    private static func normalizedASIN(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let candidate = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard candidate.count == 10,
              candidate.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 65 && scalar.value <= 90)
              }) else {
            return nil
        }
        return candidate
    }

    private static func normalizedPath(_ raw: String) -> String {
        var path = raw.lowercased()
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path.isEmpty ? "/" : path
    }

    /// Classification only; never use this as an allow decision. It lets the
    /// WebView report a rejected auth redirect separately from an arbitrary
    /// navigation while the stricter method above still enforces TLS,
    /// credentials, port, marketplace ownership, and return targets.
    static func resemblesAmazonAuthenticationURL(_ url: URL?) -> Bool {
        guard let url,
              KindleStorefront.isAmazonWebsiteDataDomain(url.host ?? "") else {
            return false
        }
        let path = url.path.lowercased()
        let queryNames = Set(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { $0.name.lowercased() }
        )
        return path.contains("/ap/signin")
            || path.contains("/ap/cvf")
            // Live evidence 2026-08-09: after the password POST Amazon routed
            // the US flow through /ap/challenge (bot/OTP challenge) with no
            // openid query. /ap/mfa is the TOTP sibling of the same step.
            || path.contains("/ap/challenge")
            || path.contains("/ap/mfa")
            || url.host?.lowercased().contains("authportal") == true
            || queryNames.contains(where: { $0.hasPrefix("openid.") })
    }

    static func isExactLibraryURL(
        _ url: URL?,
        expectedStorefrontID: String?
    ) -> Bool {
        guard allows(url, expectedStorefrontID: expectedStorefrontID),
              let url,
              let expected = KindleStorefront.entry(id: expectedStorefrontID) else {
            return false
        }
        var path = url.path.lowercased()
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path == expected.libraryURL.path.lowercased()
    }
}

private struct KindleStorefrontCatalog: Decodable {
    struct Paths: Decodable {
        let library: String
        let reader: String
    }

    let contractID: String
    let schemaVersion: Int
    let fallbackStorefrontID: String
    let readerRef: String
    let paths: Paths
    let storefronts: [KindleStorefront]
    let regionToStorefront: [String: String]
    let languageCandidateOrder: [String: [String]]
    let excludedAppLanguages: [String]

    var byID: [String: KindleStorefront] {
        Dictionary(uniqueKeysWithValues: storefronts.map { ($0.id, $0) })
    }

    var byHost: [String: KindleStorefront] {
        Dictionary(uniqueKeysWithValues: storefronts.flatMap { storefront in
            storefront.recognizedHosts.map { ($0.lowercased(), storefront) }
        })
    }

    static let shared: KindleStorefrontCatalog = {
        let bundles = [Bundle.main, Bundle(for: KindleStorefrontBundleToken.self)]
        let resourceURL = bundles.lazy.compactMap { bundle in
            bundle.url(forResource: "kindle-storefronts-v1", withExtension: "json")
                ?? bundle.url(
                    forResource: "kindle-storefronts-v1",
                    withExtension: "json",
                    subdirectory: "SharedContracts"
                )
        }.first

        guard let resourceURL,
              let data = try? Data(contentsOf: resourceURL),
              let catalog = try? JSONDecoder().decode(KindleStorefrontCatalog.self, from: data),
              catalog.contractID == "castreader-kindle-storefronts",
              catalog.schemaVersion == 1,
              catalog.paths.library == "/kindle-library",
              catalog.paths.reader == "/",
              catalog.byID[catalog.fallbackStorefrontID]?.entryEnabled == true,
              !catalog.readerRef.isEmpty,
              !catalog.storefronts.isEmpty else {
            preconditionFailure("Missing or invalid kindle-storefronts.json")
        }
        return catalog
    }()
}

private final class KindleStorefrontBundleToken {}
