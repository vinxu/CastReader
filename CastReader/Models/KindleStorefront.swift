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

    /// Returns a storefront that may be used for a new navigation. Recognition
    /// and entry are intentionally separate so historical Amazon.cn URLs can be
    /// identified without ever becoming a login or reader destination.
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
    /// safe only when it is an entry-enabled host owned by the expected active
    /// marketplace; this keeps historical CN links and cross-site redirects
    /// observable without allowing them into the current reader session.
    static func allows(_ url: URL?, expectedStorefrontID: String?) -> Bool {
        guard let expected = KindleStorefront.entry(id: expectedStorefrontID),
              let destination = KindleStorefront.entry(url: url) else {
            return false
        }
        return destination.id == expected.id
    }

    /// Main-frame navigation is deny-by-default. Besides the active Kindle
    /// storefront, the only exception is a secure Amazon-owned authentication
    /// endpoint needed to recover an expired reader session.
    static func allowsMainFrame(
        _ url: URL?,
        expectedStorefrontID: String?
    ) -> Bool {
        // A recognized Kindle host is always governed by storefront ownership,
        // even when its path resembles an auth endpoint. This prevents another
        // marketplace (and recognition-only CN) from using `/ap/signin` as an
        // authentication-exception bypass.
        if KindleStorefront.storefront(url: url) != nil {
            return allows(url, expectedStorefrontID: expectedStorefrontID)
        }
        return isSafeAmazonAuthenticationURL(url)
    }

    static func isSafeAmazonAuthenticationURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
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
