//
//  VisitorService.swift
//  CastReader
//

import Foundation

class VisitorService: ObservableObject {
    static let shared = VisitorService()

    @Published private(set) var visitorId: String

    private init() {
        if let existingId = UserDefaults.standard.string(forKey: Constants.Storage.visitorIdKey) {
            self.visitorId = existingId
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: Constants.Storage.visitorIdKey)
            self.visitorId = newId
        }
    }

    func resetVisitorId() {
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: Constants.Storage.visitorIdKey)
        self.visitorId = newId
    }
}
