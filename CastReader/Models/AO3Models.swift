import Foundation
import CryptoKit

/// AO3 History is a list of visited works, not a remote chapter/word cursor.
/// Keep CastReader's listening position separate from the imported metadata.
struct AO3Book: Codable, Identifiable, Equatable {
    var workID: String
    var title: String
    var author: String
    var account: String
    var chapterCount: String
    var readerURL: String
    var lastOpenedAt: Date?
    var position: AO3Position?
    var id: String { AO3URLPolicy.documentID(account: account, workID: workID) }
    var effectiveReaderURL: String { position?.url ?? readerURL }
}

struct AO3Position: Codable, Equatable {
    var url: String
    var paragraph: Int
    var text: String
}

struct AO3ShelfSnapshot: Decodable {
    var account: String
    var isHistory: Bool
    var books: [AO3Book]
    var nextURL: String?
}

enum AO3URLPolicy {
    static func siteURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              ["archiveofourown.org", "www.archiveofourown.org"].contains(url.host?.lowercased() ?? "") else { return nil }
        return url
    }

    static func workID(_ raw: String?) -> String? {
        guard let url = siteURL(raw) else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2 || parts.count == 4,
              parts[0] == "works", numeric(String(parts[1])),
              parts.count == 2 || (parts[2] == "chapters" && numeric(String(parts[3]))) else { return nil }
        return String(parts[1])
    }

    static func chapterURL(_ raw: String?, inWork work: String) -> URL? {
        guard workID(raw) == work, let url = siteURL(raw),
              url.path.split(separator: "/").count == 4 else { return nil }
        // Only a published chapter link, never edit/delete/comment actions.
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.query = nil
        parts.fragment = "workskin"
        return parts.url
    }

    static func historyURL(account: String, page: Int = 1) -> URL? {
        guard validAccount(account), page > 0 else { return nil }
        var url = URLComponents(string: "https://archiveofourown.org")!
        url.path = "/users/\(account)/readings"
        if page > 1 { url.queryItems = [URLQueryItem(name: "page", value: String(page))] }
        return url.url
    }

    static func isHistoryURL(_ raw: String, account: String) -> Bool {
        guard let url = siteURL(raw), validAccount(account) else { return false }
        return url.path.lowercased() == "/users/\(account)/readings".lowercased()
            && !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains { $0.name == "show" }
    }

    static func validAccount(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0)
        }
    }
    static func numeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    static func documentID(account: String, workID: String) -> String {
        let hash = SHA256.hash(data: Data(account.lowercased().utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "ao3-\(hash)-\(workID)"
    }
}
