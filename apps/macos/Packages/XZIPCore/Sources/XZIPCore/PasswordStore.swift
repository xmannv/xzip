import Foundation
import Security

/// Stores and retrieves archive passwords.
///
/// Design: the Repository pattern. Callers depend on this protocol, not on the
/// Keychain APIs, so we can substitute an in-memory store in tests and previews.
public protocol PasswordStoring: Sendable {
    func save(password: String, for key: String) throws
    func password(for key: String) throws -> String?
    func delete(for key: String) throws
    func allKeys() throws -> [String]
}

/// Errors from Keychain-backed storage.
public enum PasswordStoreError: Error, LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)
    case dataEncoding

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let s): return "Keychain error (status \(s))."
        case .dataEncoding: return "Failed to encode password data."
        }
    }
}

/// `PasswordStoring` backed by the macOS Keychain (generic passwords).
public struct KeychainPasswordStore: PasswordStoring {
    private let service: String

    public init(service: String = "com.codetay.xzip") {
        self.service = service
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    public func save(password: String, for key: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw PasswordStoreError.dataEncoding
        }

        let itemQuery = baseQuery(account: key)
        let updateStatus = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PasswordStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = itemQuery
        addQuery[kSecValueData as String] = data
        // ThisDeviceOnly: archive passwords must not sync to iCloud Keychain
        // or migrate to another Mac in a backup restore.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PasswordStoreError.unexpectedStatus(addStatus)
        }
    }

    public func password(for key: String) throws -> String? {
        var query = baseQuery(account: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw PasswordStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    public func delete(for key: String) throws {
        let query = baseQuery(account: key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordStoreError.unexpectedStatus(status)
        }
    }

    public func allKeys() throws -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw PasswordStoreError.unexpectedStatus(status)
        }
        let dicts = (items as? [[String: Any]]) ?? []
        return dicts.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// In-memory `PasswordStoring` for tests and SwiftUI previews.
///
/// Each instance owns its own lock-protected storage, so two stores never share
/// state (a previous `static` box let every instance — and every test — see each
/// other's passwords).
public final class InMemoryPasswordStore: PasswordStoring, @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        var dict: [String: String] = [:]
        let lock = NSLock()
    }
    private let box = Box()
    public init() {}

    public func save(password: String, for key: String) throws {
        box.lock.lock(); defer { box.lock.unlock() }
        box.dict[key] = password
    }
    public func password(for key: String) throws -> String? {
        box.lock.lock(); defer { box.lock.unlock() }
        return box.dict[key]
    }
    public func delete(for key: String) throws {
        box.lock.lock(); defer { box.lock.unlock() }
        box.dict[key] = nil
    }
    public func allKeys() throws -> [String] {
        box.lock.lock(); defer { box.lock.unlock() }
        return Array(box.dict.keys)
    }
}

/// Generates strong random passwords (Safari-style).
///
/// Design: a pure, stateless utility. Kept separate from the store so password
/// generation can be tested and reused without any Keychain dependency.
public enum PasswordGenerator {
    public struct Options: Sendable {
        public var length: Int
        public var includeSymbols: Bool
        public init(length: Int = 20, includeSymbols: Bool = true) {
            self.length = length
            self.includeSymbols = includeSymbols
        }
    }

    public static func generate(options: Options = .init()) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let digits = "0123456789"
        let symbols = "!@#$%^&*()-_=+[]{}"
        var alphabet = Array(letters + digits)
        if options.includeSymbols { alphabet += Array(symbols) }

        var result = ""
        for _ in 0..<max(1, options.length) {
            let idx = Int.random(in: 0..<alphabet.count)
            result.append(alphabet[idx])
        }
        return result
    }
}
