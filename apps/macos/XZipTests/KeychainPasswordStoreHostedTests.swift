import Foundation
import Security
import XCTest
import XZIPCore

final class KeychainPasswordStoreHostedTests: XCTestCase {
    private func query(
        service: String,
        account: String,
        dataProtection: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func deleteRaw(
        service: String,
        account: String,
        dataProtection: Bool
    ) {
        SecItemDelete(query(
            service: service,
            account: account,
            dataProtection: dataProtection
        ) as CFDictionary)
    }

    func testDataProtectionKeychainCRUD() throws {
        let service = "com.codetay.xzip.tests.\(UUID().uuidString)"
        let account = "archive-\(UUID().uuidString)"
        let store = KeychainPasswordStore(service: service)
        defer {
            deleteRaw(service: service, account: account, dataProtection: true)
            deleteRaw(service: service, account: account, dataProtection: false)
        }

        try store.save(password: "fresh-password", for: account)
        XCTAssertEqual(try store.password(for: account), "fresh-password")
        XCTAssertEqual(try store.allKeys(), [account])
        try store.delete(for: account)
        XCTAssertNil(try store.password(for: account))
        XCTAssertTrue(try store.allKeys().isEmpty)
    }

    func testSavingSameAccountUpdatesExistingItemWithoutDuplicate() throws {
        let service = "com.codetay.xzip.tests.\(UUID().uuidString)"
        let account = "archive-\(UUID().uuidString)"
        let store = KeychainPasswordStore(service: service)
        defer {
            deleteRaw(service: service, account: account, dataProtection: true)
            deleteRaw(service: service, account: account, dataProtection: false)
        }

        try store.save(password: "first-password", for: account)
        var persistentReferenceQuery = query(
            service: service,
            account: account,
            dataProtection: true
        )
        persistentReferenceQuery[kSecReturnPersistentRef as String] = true
        persistentReferenceQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var initialReference: CFTypeRef?
        XCTAssertEqual(
            SecItemCopyMatching(
                persistentReferenceQuery as CFDictionary,
                &initialReference
            ),
            errSecSuccess
        )

        try store.save(password: "updated-password", for: account)

        XCTAssertEqual(try store.password(for: account), "updated-password")
        XCTAssertEqual(try store.allKeys(), [account])
        var updatedReference: CFTypeRef?
        XCTAssertEqual(
            SecItemCopyMatching(
                persistentReferenceQuery as CFDictionary,
                &updatedReference
            ),
            errSecSuccess
        )
        XCTAssertEqual(initialReference as? Data, updatedReference as? Data)
    }

    func testLegacyItemIsNotReadMigratedOrDeleted() throws {
        let service = "com.codetay.xzip.tests.\(UUID().uuidString)"
        let account = "archive-\(UUID().uuidString)"
        let store = KeychainPasswordStore(service: service)
        defer {
            deleteRaw(service: service, account: account, dataProtection: true)
            deleteRaw(service: service, account: account, dataProtection: false)
        }

        var legacyQuery = query(
            service: service,
            account: account,
            dataProtection: false
        )
        legacyQuery[kSecValueData as String] = Data("legacy-password".utf8)
        legacyQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(legacyQuery as CFDictionary, nil), errSecSuccess)

        XCTAssertNil(try store.password(for: account))
        XCTAssertFalse(try store.allKeys().contains(account))

        try store.save(password: "fresh-password", for: account)
        XCTAssertEqual(try store.password(for: account), "fresh-password")
        try store.delete(for: account)

        var legacyRead = legacyQuery
        legacyRead.removeValue(forKey: kSecValueData as String)
        legacyRead.removeValue(forKey: kSecAttrAccessible as String)
        legacyRead[kSecReturnData as String] = true
        legacyRead[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        XCTAssertEqual(
            SecItemCopyMatching(legacyRead as CFDictionary, &item),
            errSecSuccess
        )
        XCTAssertEqual(String(data: item as! Data, encoding: .utf8), "legacy-password")
    }
}
