import Foundation

/// Authentication owns its presentation independently from shelf discovery.
/// Scanning may begin only after the official page proves it is a shelf.
enum KoboBindingPhase: Equatable {
    case opening
    case awaitingLogin
    case authenticating
    case scanning
    case ready
    case synced
    case failed
}

/// This inexpensive probe contains only page-shape evidence. It never carries
/// input values, account identifiers, credentials, cookies, or redirect URLs.
struct KoboBindingPageProbe {
    let hasCredentialForm: Bool
    let hasSignInControl: Bool
    let hasAccountEvidence: Bool
    let isShelfContext: Bool
    let isBlank: Bool
    let isLoading: Bool
    let hasShelfBooks: Bool

    init(_ raw: [String: Any]) {
        hasCredentialForm = raw["hasCredentialForm"] as? Bool ?? false
        hasSignInControl = raw["hasSignInControl"] as? Bool ?? false
        hasAccountEvidence = raw["hasAccountEvidence"] as? Bool ?? false
        isShelfContext = raw["isShelfContext"] as? Bool ?? false
        isBlank = raw["isBlank"] as? Bool ?? true
        isLoading = raw["isLoading"] as? Bool ?? true
        hasShelfBooks = raw["hasShelfBooks"] as? Bool ?? false
    }

    var canScanShelf: Bool {
        isShelfContext && !isLoading && !isBlank
            && hasAccountEvidence && !hasCredentialForm
    }

    func canStartShelfScan(at url: URL?, hasCommittedDocument: Bool) -> Bool {
        // WKWebView.isLoading also waits for analytics/advertising resources.
        // Use the committed official document and its own ready shelf state.
        hasCommittedDocument && KoboWebScripts.isShelfURL(url) && canScanShelf
    }
}

enum KoboBindingFlowContract {
    static func isCredentialURL(_ url: URL?) -> Bool {
        guard KoboWebScripts.allowsBindingNavigation(url),
              let url,
              let host = url.host?.lowercased(),
              !KoboWebAccessPolicy.allowsLibraryURL(url) else { return false }
        if host == "accounts.google.com" || host == "appleid.apple.com"
            || isGoogleContinuation(url) {
            return true
        }
        let authenticationHosts: Set<String> = [
            "account", "accounts", "auth", "authenticate", "authentication",
            "authorize", "id", "login", "member", "membership", "signin", "sso",
        ]
        if host.split(separator: ".").contains(where: {
            authenticationHosts.contains(String($0))
        }) { return true }
        let authenticationRoutes: Set<String> = [
            "auth", "authenticate", "authentication", "authorize", "authorization",
            "challenge", "connect", "login", "log-in", "loginupdate",
            "oauth", "oauth2", "signin", "sign-in", "sign_in", "signon",
            "sign-on", "sso", "verify", "verification",
        ]
        return url.path.lowercased().split(separator: "/").contains {
            authenticationRoutes.contains(String($0))
        }
    }

    /// Blank popup bootstrapping is separate from the HTTPS navigation policy.
    /// The caller must also verify this is a real popup request, never a new
    /// top-level destination supplied by an arbitrary page.
    static func allowsPopupBootstrap(_ url: URL?, openerURL: URL?) -> Bool {
        guard url == nil || url?.absoluteString == "about:blank" else { return false }
        return KoboWebScripts.allowsBindingNavigation(openerURL)
    }

    /// Log only a route category. OAuth paths and query values can themselves
    /// contain account identifiers, authorization codes or continuation tokens.
    static func safeRouteLabel(_ url: URL?) -> String {
        guard let url else { return "unknown" }
        if url.absoluteString == "about:blank" { return "about:blank" }
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return "unsupported" }
        let category: String
        if KoboWebAccessPolicy.allowsLibraryURL(url) {
            category = "shelf"
        } else if isGoogleContinuation(url) {
            category = "continuation"
        } else if isCredentialURL(url) {
            category = "credentials"
        } else {
            category = "other"
        }
        return host + "/" + category
    }

    /// Resolve only known Google continuation wrappers that terminate at an
    /// exact Kobo shelf. A Google landing page by itself is never login proof.
    static func trustedShelfContinuation(_ url: URL?) -> URL? {
        guard var candidate = url else { return nil }
        var visited: Set<String> = []
        for _ in 0..<5 {
            guard candidate.absoluteString.utf8.count <= 8_192,
                  visited.insert(candidate.absoluteString).inserted else { return nil }
            if KoboWebAccessPolicy.allowsLibraryURL(candidate) { return candidate }
            guard isGoogleContinuation(candidate),
                  let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else {
                return nil
            }
            let continuations = (components.queryItems ?? []).filter {
                $0.name.lowercased() == "continue"
            }
            guard continuations.count == 1,
                  let raw = continuations.first?.value,
                  let next = URL(string: raw),
                  next.scheme?.lowercased() == "https" else { return nil }
            candidate = next
        }
        return nil
    }

    private static func isGoogleContinuation(_ url: URL) -> Bool {
        guard KoboWebScripts.allowsBindingNavigation(url),
              let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        return (host == "accounts.google.com" && path == "/checkcookie")
            || (host == "gds.google.com" && (path == "/web/landing" || path == "/web/landing/"))
    }
}
