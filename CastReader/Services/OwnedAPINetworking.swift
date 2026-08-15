//
//  OwnedAPINetworking.swift
//  CastReader
//
//  Redirect boundary for CastReader-owned API traffic. A frozen global/CN
//  process must never follow a server-side redirect across gateway ingress.
//

import Foundation

enum OwnedAPIRedirectPolicy {
    static let globalGatewayHost = "api.castreader.ai"
    static let chinaGatewayHost = "api.castreader.cn"
    static let chinaQuickReadHost = "quickread.castreader.cn"

    static func gatewayHost(for route: ServiceRoute) -> String {
        switch route {
        case .globalGateway: return globalGatewayHost
        case .chinaGateway: return chinaGatewayHost
        }
    }

    /// Response-provided legacy URLs may be rewritten only when the China
    /// gateway has an explicit path contract for the same resource. At the
    /// moment Nginx exposes `/api/tts/` as a path-preserving proxy (catalog
    /// media included). Document Markdown/covers are returned on third-party
    /// R2/COS/CDN hosts and therefore do not need an owned-host rewrite.
    ///
    /// Keep this allowlist in lockstep with
    /// `scripts/nginx-api-castreader-cn.conf`. A generic owned-host rewrite can
    /// appear safe while silently converting a valid `.ai` URL into a `.cn`
    /// 404, or routing a future endpoint through an unreviewed gateway path.
    static func isChinaGatewayBackedResponsePath(_ path: String) -> Bool {
        path.hasPrefix("/api/tts/")
    }

    /// CastReader-controlled hosts which may appear in legacy responses or
    /// configuration. Suffix matching also covers retired subdomains without
    /// weakening the separate third-party OAuth/COS/bookshelf sessions.
    static func isCastReaderOwnedHost(_ rawHost: String?) -> Bool {
        guard let host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !host.isEmpty else {
            return false
        }
        return host == "castreader.ai"
            || host.hasSuffix(".castreader.ai")
            || host == "castreader.com"
            || host.hasSuffix(".castreader.com")
            || host == "castreader.cn"
            || host.hasSuffix(".castreader.cn")
    }

    /// Pure policy used by the URLSession delegate and contract tests.
    ///
    /// - First-party request: only an HTTPS redirect that remains on the route's
    ///   exact gateway is accepted. This blocks credential/body replay across
    ///   global/CN ingress and to every retired `.ai`/`.com` host.
    /// - Third-party request: outside this boundary, so OAuth, COS and shelf
    ///   providers retain their existing redirect behavior.
    static func allowsRedirect(
        route: ServiceRoute,
        originalURL: URL?,
        proposedURL: URL?
    ) -> Bool {
        guard isCastReaderOwnedHost(originalURL?.host) else { return true }
        // CN QuickRead is a separate, compile-time-pinned first-party ingress.
        // A redirect may stay on that exact host, but it must never replay a
        // cms_ bearer or document body to api.castreader.cn or any `.ai` host.
        let originalHost = originalURL?.host?.lowercased()
        let expectedHost = route == .chinaGateway && originalHost == chinaQuickReadHost
            ? chinaQuickReadHost
            : gatewayHost(for: route)
        guard let components = proposedURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == expectedHost,
              components.user == nil,
              components.password == nil else {
            return false
        }

        // The public gateway is defined on standard HTTPS. A redirect to a
        // surprising port would bypass that deployment boundary.
        return components.port == nil || components.port == 443
    }

    /// Normalizes CastReader-owned URLs received inside an API response before
    /// another subsystem (markdown loader, AsyncImage, Now Playing artwork)
    /// can turn them into a fresh request. Request delegates only see a URL
    /// after that request has started, so this response boundary is required to
    /// prevent a CN process from initially touching an old `.ai`/`.com` host.
    ///
    /// Third-party assets remain byte-for-byte unchanged. Each route accepts an
    /// already-issued standard-HTTPS URL on its exact gateway. CN may additionally
    /// rewrite only a proven path on the exact global gateway. Every other
    /// owned-host URL fails closed; inventing a
    /// gateway URL for an unproxied path would merely turn a valid response into
    /// a delayed 404 and would hide a missing deployment contract.
    static func routedResponseURL(
        _ originalURL: URL,
        route: ServiceRoute = ServiceRouting.current
    ) -> URL? {
        guard isCastReaderOwnedHost(originalURL.host) else {
            return originalURL
        }
        guard var components = URLComponents(
            url: originalURL,
            resolvingAgainstBaseURL: false
        ),
        components.scheme?.lowercased() == "https",
        let host = components.host?.lowercased(),
        components.user == nil,
        components.password == nil,
        components.port == nil || components.port == 443 else {
            return nil
        }

        let expectedHost = gatewayHost(for: route)
        if host == expectedHost {
            components.scheme = "https"
            components.host = expectedHost
            components.port = nil
            return components.url
        }

        if route == .chinaGateway,
           host == chinaQuickReadHost,
           components.path.hasPrefix("/api/quickread/") {
            components.scheme = "https"
            components.host = chinaQuickReadHost
            components.port = nil
            return components.url
        }

        guard route == .chinaGateway,
              host == globalGatewayHost,
              isChinaGatewayBackedResponsePath(components.path) else {
            return nil
        }
        components.scheme = "https"
        components.host = chinaGatewayHost
        components.port = nil
        return components.url
    }

    static func routedResponseURLString(
        _ rawValue: String?,
        route: ServiceRoute = ServiceRouting.current
    ) -> String? {
        guard let rawValue else { return nil }
        guard let url = URL(string: rawValue) else { return nil }
        return routedResponseURL(url, route: route)?.absoluteString
    }
}

final class OwnedAPIRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let route: ServiceRoute
    private let rejectsEveryRedirect: Bool

    init(route: ServiceRoute, rejectsEveryRedirect: Bool = false) {
        self.route = route
        self.rejectsEveryRedirect = rejectsEveryRedirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard !rejectsEveryRedirect else {
            completionHandler(nil)
            return
        }
        let originalURL = task.originalRequest?.url ?? task.currentRequest?.url
        completionHandler(
            OwnedAPIRedirectPolicy.allowsRedirect(
                route: route,
                originalURL: originalURL,
                proposedURL: request.url
            ) ? request : nil
        )
    }
}

enum OwnedAPIURLSession {
    /// Shared production client for short JSON requests. Initialization is lazy
    /// and therefore observes the app process's already-frozen service route.
    static let shared = make()
    private static let responseSessions: [ServiceRoute: URLSession] = Dictionary(
        uniqueKeysWithValues: ServiceRoute.allCases.map { route in
            (route, makeExplicitCredentialSession(route: route))
        }
    )

    /// Cookie-free transport for requests whose identity contract is explicit
    /// (`Authorization: Bearer cms_|cmc_`) or anonymous (TTS/catalog/media).
    /// Better Auth and provider sign-in sessions deliberately do not use this
    /// factory because their account flows may require their own cookie state.
    static func explicitCredentialConfiguration(
        requestTimeout: TimeInterval? = nil,
        resourceTimeout: TimeInterval? = nil
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        if let requestTimeout {
            configuration.timeoutIntervalForRequest = requestTimeout
        }
        if let resourceTimeout {
            configuration.timeoutIntervalForResource = resourceTimeout
        }
        return configuration
    }

    static func makeExplicitCredentialSession(
        route: ServiceRoute,
        requestTimeout: TimeInterval? = nil,
        resourceTimeout: TimeInterval? = nil,
        rejectsEveryRedirect: Bool = false
    ) -> URLSession {
        make(
            configuration: explicitCredentialConfiguration(
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout
            ),
            route: route,
            rejectsEveryRedirect: rejectsEveryRedirect
        )
    }

    /// Runtime configuration is mirrored on both public gateways. Bind the
    /// no-redirect control-plane session to the process's already-frozen route
    /// so even its first request cannot cross global/CN ingress.
    static func controlPlane(for route: ServiceRoute = ServiceRouting.current) -> URLSession {
        makeExplicitCredentialSession(
            route: route,
            rejectsEveryRedirect: true
        )
    }

    static func make(
        configuration: URLSessionConfiguration = .default,
        route: ServiceRoute = ServiceRouting.current,
        rejectsEveryRedirect: Bool = false
    ) -> URLSession {
        let copied = configuration.copy() as? URLSessionConfiguration ?? configuration
        return URLSession(
            configuration: copied,
            delegate: OwnedAPIRedirectDelegate(
                route: route,
                rejectsEveryRedirect: rejectsEveryRedirect
            ),
            delegateQueue: nil
        )
    }

    /// Safe convenience for response-provided URLs. This both rewrites the
    /// initial CN first-party destination and applies the no-cross-line
    /// redirect delegate. Third-party URLs retain normal URLSession behavior.
    static func data(
        from responseURL: URL,
        route: ServiceRoute = ServiceRouting.current
    ) async throws -> (Data, URLResponse) {
        guard let routedURL = OwnedAPIRedirectPolicy.routedResponseURL(
            responseURL,
            route: route
        ) else {
            throw URLError(.unsupportedURL)
        }
        guard let session = responseSessions[route] else {
            throw URLError(.unsupportedURL)
        }
        return try await session.data(from: routedURL)
    }
}
