//
//  StableDeviceID.swift
//  CastReader
//
//  Anonymous quota identity. Stored in Keychain so reinstalling the app does
//  not mint a fresh free quota bucket.
//

import Foundation

enum StableDeviceID {
    /// Keep the existing global keys across the app upgrade. CN receives a
    /// distinct anonymous/device identity so quota, device links and review
    /// testing cannot overwrite the global route. Shared Pro ownership is
    /// resolved by canonical user.id, never by reusing a device id across routes.
    static func keychainKey(for route: ServiceRoute) -> String {
        route.isolatedStorageKey("stable_device_id")
    }

    static func defaultsKey(for route: ServiceRoute) -> String {
        route.isolatedStorageKey(Constants.Storage.visitorIdKey)
    }

    static var current: String {
        current(for: ServiceRouting.current)
    }

    private static func current(for route: ServiceRoute) -> String {
        let keychainKey = keychainKey(for: route)
        let defaultsKey = defaultsKey(for: route)
        let defaults = UserDefaults.standard
        if let id = KeychainStore.get(keychainKey), !id.isEmpty {
            defaults.set(id, forKey: defaultsKey)
            return id
        }
        if let legacy = defaults.string(forKey: defaultsKey), !legacy.isEmpty {
            KeychainStore.set(legacy, for: keychainKey)
            return legacy
        }
        let id = UUID().uuidString
        KeychainStore.set(id, for: keychainKey)
        defaults.set(id, forKey: defaultsKey)
        return id
    }

    static func rotateForTesting() -> String {
        let route = ServiceRouting.current
        let keychainKey = keychainKey(for: route)
        let defaultsKey = defaultsKey(for: route)
        let id = UUID().uuidString
        KeychainStore.set(id, for: keychainKey)
        UserDefaults.standard.set(id, forKey: defaultsKey)
        return id
    }
}
