//
//  VisitorService.swift
//  CastReader
//

import Foundation

class VisitorService: ObservableObject {
    static let shared = VisitorService()

    @Published private(set) var visitorId: String

    private init() {
        self.visitorId = StableDeviceID.current
    }

    func resetVisitorId() {
        self.visitorId = StableDeviceID.rotateForTesting()
    }
}
