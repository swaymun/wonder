import Foundation
import Security
import CryptoKit

public enum RelayKeychainError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidKeyLength
}

/// Device-only storage for the separate X25519 Noise identity. Raw X25519
/// keys are intentionally not represented by Secure Enclave key types: this
/// key is loaded by the Rust `snow` FFI and is distinct from the P-256 signing
/// identity used by pairing.
public struct RelayKeychain: Sendable {
    // Security.framework calls are synchronous. Keep this process's operations
    // serial; SecItemAdd still arbitrates identity creation across processes.
    private static let accessLock = NSRecursiveLock()
    public let service: String

    public init(service: String = "com.saimun.wonder.native-relay") {
        self.service = service
    }

    public func read(account: String) throws -> Data? {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw RelayKeychainError.keychain(status) }
        guard data.count == 32 else { throw RelayKeychainError.invalidKeyLength }
        return data
    }

    public func save(_ rawKey: Data, account: String) throws {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        guard rawKey.count == 32 else { throw RelayKeychainError.invalidKeyLength }
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: rawKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw RelayKeychainError.keychain(addStatus)
            }
        } else if update != errSecSuccess {
            throw RelayKeychainError.keychain(update)
        }
    }

    public func delete(account: String) throws {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RelayKeychainError.keychain(status) }
    }

    public func readOrCreate(account: String = "noise-static") throws -> Data {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        if let existing = try read(account: account) { return existing }
        let key = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        do {
            try add(key, account: account)
            return key
        } catch RelayKeychainError.keychain(let status) where status == errSecDuplicateItem {
            // Another caller won the create race. Never overwrite the winner;
            // load its value and use that identity for this connection.
            guard let existing = try read(account: account) else { throw RelayKeychainError.keychain(errSecItemNotFound) }
            return existing
        }
    }

    private func add(_ rawKey: Data, account: String) throws {
        guard rawKey.count == 32 else { throw RelayKeychainError.invalidKeyLength }
        var item = baseQuery(account: account)
        item[kSecValueData as String] = rawKey
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw RelayKeychainError.keychain(status) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
