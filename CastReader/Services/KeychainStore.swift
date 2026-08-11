//
//  KeychainStore.swift
//  CastReader
//
//  CastReader-owned secrets live in the app's private application-identifier
//  access group. MSAL keeps its independent com.microsoft.adalcache group.
//

import Foundation
import Security

struct KeychainStoredItem: Equatable {
    let data: Data
    let accessibility: String
}

protocol KeychainItemClient: AnyObject {
    func read(service: String, account: String, accessGroup: String) -> KeychainStoredItem?

    @discardableResult
    func write(
        data: Data,
        service: String,
        account: String,
        accessGroup: String,
        accessibility: String
    ) -> OSStatus

    @discardableResult
    func delete(service: String, account: String, accessGroup: String) -> OSStatus
}

final class SystemKeychainItemClient: KeychainItemClient {
    func read(service: String, account: String, accessGroup: String) -> KeychainStoredItem? {
        var query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data else {
            return nil
        }
        let accessibility = attributes[kSecAttrAccessible as String] as? String
            ?? (kSecAttrAccessibleAfterFirstUnlock as String)
        return KeychainStoredItem(data: data, accessibility: accessibility)
    }

    func write(
        data: Data,
        service: String,
        account: String,
        accessGroup: String,
        accessibility: String
    ) -> OSStatus {
        let query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var add = query
        values.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, values as CFDictionary)
        }
        return addStatus
    }

    func delete(service: String, account: String, accessGroup: String) -> OSStatus {
        SecItemDelete(
            baseQuery(service: service, account: account, accessGroup: accessGroup) as CFDictionary
        )
    }

    private func baseQuery(
        service: String,
        account: String,
        accessGroup: String
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Unsigned simulator test hosts have no application-identifier
        // entitlement and Xcode leaves AppIdentifierPrefix unsubstituted.
        // Omitting the group uses that test process's default Keychain only;
        // signed app builds always pass the explicit private group below.
        if !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

struct KeychainAccessGroupConfiguration: Equatable {
    static let infoPlistKey = "CastReaderPrivateKeychainAccessGroup"
    static let microsoftLegacySuffix = "com.microsoft.adalcache"

    let privateAccessGroup: String
    let legacyAccessGroups: [String]

    private init(privateAccessGroup: String, legacyAccessGroups: [String]) {
        self.privateAccessGroup = privateAccessGroup
        self.legacyAccessGroups = legacyAccessGroups
    }

    init?(privateAccessGroup rawGroup: String, bundleIdentifier: String) {
        let group = rawGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !group.isEmpty,
              !identifier.isEmpty,
              !group.contains("$("),
              group.hasSuffix(identifier) else {
            return nil
        }

        let prefix = String(group.dropLast(identifier.count))
        guard !prefix.isEmpty, prefix.hasSuffix(".") else { return nil }

        privateAccessGroup = group
        legacyAccessGroups = [prefix + Self.microsoftLegacySuffix]
            .filter { $0 != group }
    }

    /// Only for an unsigned iOS Simulator XCTest host. An empty group makes
    /// Security use the process default instead of a non-existent entitlement.
    static var unsignedSimulatorTestFallback: KeychainAccessGroupConfiguration {
        KeychainAccessGroupConfiguration(
            privateAccessGroup: "",
            legacyAccessGroups: []
        )
    }

    static func current(bundle: Bundle = .main) -> KeychainAccessGroupConfiguration? {
        guard let rawGroup = bundle.object(
            forInfoDictionaryKey: Self.infoPlistKey
        ) as? String,
              let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }
        return KeychainAccessGroupConfiguration(
            privateAccessGroup: rawGroup,
            bundleIdentifier: bundleIdentifier
        )
    }
}

struct KeychainRepository {
    let service: String
    let configuration: KeychainAccessGroupConfiguration
    let client: KeychainItemClient

    @discardableResult
    func set(_ value: String, for key: String, accessibility: String) -> Bool {
        let status = client.write(
            data: Data(value.utf8),
            service: service,
            account: key,
            accessGroup: configuration.privateAccessGroup,
            accessibility: accessibility
        )
        guard status == errSecSuccess else { return false }
        removeLegacyCopies(for: key)
        return true
    }

    func get(_ key: String) -> String? {
        if let privateItem = client.read(
            service: service,
            account: key,
            accessGroup: configuration.privateAccessGroup
        ), let value = String(data: privateItem.data, encoding: .utf8) {
            // A previous build could have left the same CastReader item in the
            // MSAL group. Once the private copy is known-good, erase that copy.
            removeLegacyCopies(for: key)
            return value
        }

        for legacyGroup in configuration.legacyAccessGroups {
            guard let legacyItem = client.read(
                service: service,
                account: key,
                accessGroup: legacyGroup
            ), let value = String(data: legacyItem.data, encoding: .utf8) else {
                continue
            }

            // Migrate only after the private write succeeds. A failed write
            // keeps the legacy item readable, preventing an account/device-ID
            // loss during a transient Keychain or signing failure.
            let status = client.write(
                data: legacyItem.data,
                service: service,
                account: key,
                accessGroup: configuration.privateAccessGroup,
                accessibility: legacyItem.accessibility
            )
            if status == errSecSuccess {
                _ = client.delete(
                    service: service,
                    account: key,
                    accessGroup: legacyGroup
                )
            }
            return value
        }
        return nil
    }

    func delete(_ key: String) {
        _ = client.delete(
            service: service,
            account: key,
            accessGroup: configuration.privateAccessGroup
        )
        removeLegacyCopies(for: key)
    }

    private func removeLegacyCopies(for key: String) {
        for group in configuration.legacyAccessGroups {
            _ = client.delete(service: service, account: key, accessGroup: group)
        }
    }
}

enum KeychainStore {
    private static let service = "ai.castreader.auth"
    private static let client = SystemKeychainItemClient()
    private static let operationLock = NSLock()

    private static var repository: KeychainRepository? {
        let configuration: KeychainAccessGroupConfiguration
        if let configured = KeychainAccessGroupConfiguration.current() {
            configuration = configured
        } else if isUnsignedSimulatorTestHost {
            configuration = .unsignedSimulatorTestFallback
        } else {
            assertionFailure("Missing or invalid private Keychain access-group configuration")
            return nil
        }
        return KeychainRepository(
            service: service,
            configuration: configuration,
            client: client
        )
    }

    private static var isUnsignedSimulatorTestHost: Bool {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
        #else
        return false
        #endif
    }

    @discardableResult
    static func set(
        _ value: String,
        for key: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return repository?.set(value, for: key, accessibility: accessibility as String) ?? false
    }

    static func get(_ key: String) -> String? {
        operationLock.lock()
        defer { operationLock.unlock() }
        return repository?.get(key)
    }

    static func delete(_ key: String) {
        operationLock.lock()
        defer { operationLock.unlock() }
        repository?.delete(key)
    }
}
