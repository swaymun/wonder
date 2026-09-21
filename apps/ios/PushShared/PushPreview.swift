import Foundation
import CryptoKit
import Security

struct PushPreview: Codable, Equatable {
    let title: String
    let body: String

    static func decrypt(_ payload: [String: String], key: Data) throws -> Self {
        guard let registration = payload["registrationId"], UUID(uuidString: registration) != nil,
              let route = payload["routeId"], UUID(uuidString: route) != nil,
              let event = payload["eventId"], UUID(uuidString: event) != nil,
              let encoded = payload["preview"], encoded.utf8.count <= 3240,
              let combined = Data(pushBase64URL: encoded), key.count == 32 else { throw PreviewError.invalid }
        let aad = Data("wonder-push-v1\n\(registration)\n\(route)\n\(event)".utf8)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: key), authenticating: aad)
        guard plain.count <= 2400 else { throw PreviewError.invalid }
        let preview = try JSONDecoder().decode(Self.self, from: plain)
        guard !preview.title.isEmpty, !preview.body.isEmpty, preview.title.utf8.count <= 163, preview.body.utf8.count <= 1003 else { throw PreviewError.invalid }
        return preview
    }
}

enum PreviewError: Error { case invalid, keychain(OSStatus) }

/// This group contains only per-registration preview keys. Pairing and signing
/// credentials remain in the application's original, private Keychain group.
enum PushPreviewKeys {
    private static func query(_ registration: String) throws -> [String: Any] {
        guard UUID(uuidString: registration) != nil,
              let group = Bundle.main.object(forInfoDictionaryKey: "WonderPushKeychainGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { throw PreviewError.invalid }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "wonder.push.previews.v1",
                kSecAttrAccount as String: registration, kSecAttrAccessGroup as String: group]
    }
    static func read(_ registration: String) throws -> Data? {
        var query = try query(registration); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw PreviewError.keychain(status) }
        return data
    }
    static func getOrCreate(_ registration: String) throws -> Data {
        if let key = try read(registration) { return key }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PreviewError.keychain(status) }
        var item = try query(registration); item[kSecValueData as String] = bytes
        // Available to the extension while locked after the first device unlock.
        // These keys never synchronize to iCloud or migrate to a different phone.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem, let existing = try read(registration) { return existing }
        guard added == errSecSuccess else { throw PreviewError.keychain(added) }
        return bytes
    }
    static func remove(_ registration: String) throws {
        let status = SecItemDelete(try query(registration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PreviewError.keychain(status) }
    }
}

extension Data {
    init?(pushBase64URL text: String) {
        let normalized = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4))
    }
}
