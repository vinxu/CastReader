//
//  StableDeviceID.swift
//  CastReader
//
//  Anonymous quota identity. Stored in Keychain so reinstalling the app does
//  not mint a fresh free quota bucket.
//

import Foundation

enum StableDeviceID {
    private static let keychainKey = "stable_device_id"

    static var current: String {
        let defaults = UserDefaults.standard
        if let id = KeychainStore.get(keychainKey), !id.isEmpty {
            defaults.set(id, forKey: Constants.Storage.visitorIdKey)
            return id
        }
        if let legacy = defaults.string(forKey: Constants.Storage.visitorIdKey), !legacy.isEmpty {
            KeychainStore.set(legacy, for: keychainKey)
            return legacy
        }
        let id = UUID().uuidString
        KeychainStore.set(id, for: keychainKey)
        defaults.set(id, forKey: Constants.Storage.visitorIdKey)
        return id
    }

    static func rotateForTesting() -> String {
        let id = UUID().uuidString
        KeychainStore.set(id, for: keychainKey)
        UserDefaults.standard.set(id, forKey: Constants.Storage.visitorIdKey)
        return id
    }
}
