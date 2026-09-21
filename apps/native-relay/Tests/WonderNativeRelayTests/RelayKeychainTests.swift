import CryptoKit
import Security
import XCTest
@testable import WonderNativeRelay

final class RelayKeychainTests: XCTestCase {
    func testRawKeyIsDeviceOnlyAndNonSynchronizing() throws {
        let service = "com.saimun.wonder.native-relay.test.\(UUID().uuidString)"
        let account = "noise-static"
        let keychain = RelayKeychain(service: service)
        defer { try? keychain.delete(account: account) }

        let raw = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        try keychain.save(raw, account: account)
        XCTAssertEqual(try keychain.read(account: account), raw)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        XCTAssertEqual(result as? Data, raw)
    }

    func testInvalidLengthIsRejectedAndExactEntryIsCleanedUp() throws {
        let service = "com.saimun.wonder.native-relay.test.\(UUID().uuidString)"
        let account = "invalid"
        let keychain = RelayKeychain(service: service)
        XCTAssertThrowsError(try keychain.save(Data(repeating: 0, count: 31), account: account))
        try keychain.delete(account: account)
        XCTAssertNil(try keychain.read(account: account))
    }

    func testReadOrCreateKeepsOneIdentity() throws {
        let service = "com.saimun.wonder.native-relay.test.\(UUID().uuidString)"
        let account = "noise-static"
        let keychain = RelayKeychain(service: service)
        defer { try? keychain.delete(account: account) }
        let first = try keychain.readOrCreate(account: account)
        XCTAssertEqual(try keychain.readOrCreate(account: account), first)
    }

    func testReadOrCreateIsAtomicAcrossConcurrentCreators() throws {
        let service = "com.saimun.wonder.native-relay.test.\(UUID().uuidString)"
        print("Relay concurrent Keychain test service: \(service)")
        let account = "noise-static"
        let keychain = RelayKeychain(service: service)
        defer { try? keychain.delete(account: account) }

        // Blocking Security calls must not occupy Swift's cooperative executor.
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var entries: [Result<Data, Error>] = []
            func append(_ result: Result<Data, Error>) {
                lock.lock()
                defer { lock.unlock() }
                entries.append(result)
            }
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.append(Result { try keychain.readOrCreate(account: account) })
        }
        let values = try results.entries.map { try $0.get() }
        XCTAssertEqual(values.count, 8)
        XCTAssertEqual(Set(values).count, 1)
    }
}
