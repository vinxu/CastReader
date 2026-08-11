//
//  NetworkReachability.swift
//  CastReader
//
//  Coarse online/offline signal for surfaces that would otherwise make the
//  user wait out a full network timeout to learn there is no network.
//

import Combine
import Foundation
import Network

@MainActor
final class NetworkReachability: ObservableObject {
    static let shared = NetworkReachability()

    /// Starts optimistic and never latches offline on its own. Every consumer
    /// treats this as a hint: an action that is merely *likely* to fail must
    /// still be reachable if the user insists, because a captive portal or a
    /// stale path update can make this wrong.
    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.castreader.network-reachability")
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status != .unsatisfied
            Task { @MainActor [weak self] in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }
}
