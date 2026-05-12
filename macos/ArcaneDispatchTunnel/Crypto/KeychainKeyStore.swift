// Keychain-backed persistence for the bonded transport's static keys.
//
// We persist two distinct items:
//
//   * The local client identity — a 32-byte X25519 private key generated
//     once per install and reused across every Noise IK handshake. The
//     server learns this client's public key the first time we connect
//     (Speedify-style: trust-on-first-use; the admin can later promote
//     the client to a named account via `dispatch-speed-server adduser`).
//
//   * The server's static public key — handed to the user as a base64
//     blob next to the server URL. We cache it under a separate Keychain
//     item so subsequent reconnects don't need to re-parse the config
//     payload.
//
// Storage choice: kSecClassGenericPassword with kSecAttrAccessible set
// to *AfterFirstUnlock so the tunnel extension (which boots at login,
// before the user re-types the password) can still read the key. We
// intentionally do *not* use access groups — the System Extension lives
// in the same Keychain access scope as the container app.
//
// Threading: SecItem* APIs are thread-safe. The wrapper is a pure
// function namespace.

import CryptoKit
import Foundation

public enum KeychainKeyStore {
    /// Service name used for all Keychain queries we own. Bumping this
    /// effectively wipes existing keys (useful for emergency rotation).
    public static let service = "art.arcane.dispatch.crypto.v1"

    /// Account names for the two stored items.
    private static let clientIdentityAccount = "client-identity"
    private static let responderPublicAccount = "responder-public"

    public enum Failure: Error, CustomStringConvertible {
        case osStatus(OSStatus, String)
        case badSize(Int)
        case unexpectedType

        public var description: String {
            switch self {
            case .osStatus(let status, let op):
                return "keychain: \(op) failed: OSStatus=\(status)"
            case .badSize(let n):
                return "keychain: stored key is wrong size (\(n) bytes; expected 32)"
            case .unexpectedType:
                return "keychain: stored item has wrong type"
            }
        }
    }

    // MARK: - Client identity

    /// Returns the persisted client X25519 keypair, generating + storing
    /// a new one on the first call. The Keychain item itself only holds
    /// the 32-byte private scalar; the public point is derived on read.
    public static func loadOrCreateClientIdentity() throws -> NoiseKeypair {
        if let existing = try loadPrivateKey(account: clientIdentityAccount) {
            return existing
        }
        let fresh = NoiseKeypair.generate()
        try store(privateKey: fresh.priv, account: clientIdentityAccount)
        return fresh
    }

    /// Force-replaces the client identity with a fresh keypair. Used by
    /// the "wipe local identity" UI control.
    @discardableResult
    public static func resetClientIdentity() throws -> NoiseKeypair {
        try deletePrivateKey(account: clientIdentityAccount)
        let fresh = NoiseKeypair.generate()
        try store(privateKey: fresh.priv, account: clientIdentityAccount)
        return fresh
    }

    // MARK: - Responder static key

    /// Cached responder public key. Returns nil if the user hasn't yet
    /// configured a server.
    public static func loadResponderPublicKey() throws -> Data? {
        try loadPublicKey(account: responderPublicAccount)
    }

    /// Stores the responder public key. Called from the "Connect to
    /// server" UI flow after the user pastes the server URL+key blob.
    public static func saveResponderPublicKey(_ pub: Data) throws {
        guard pub.count == 32 else {
            throw Failure.badSize(pub.count)
        }
        try storePublic(pub: pub, account: responderPublicAccount)
    }

    /// Removes the cached responder public key (e.g. user disconnects).
    public static func clearResponderPublicKey() throws {
        try deletePrivateKey(account: responderPublicAccount)
    }

    // MARK: - Private helpers

    private static func loadPrivateKey(account: String) throws -> NoiseKeypair? {
        guard let raw = try loadRaw(account: account) else { return nil }
        guard raw.count == 32 else { throw Failure.badSize(raw.count) }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        return NoiseKeypair(
            priv: Data(key.rawRepresentation),
            pub: Data(key.publicKey.rawRepresentation),
        )
    }

    private static func loadPublicKey(account: String) throws -> Data? {
        guard let raw = try loadRaw(account: account) else { return nil }
        guard raw.count == 32 else { throw Failure.badSize(raw.count) }
        return raw
    }

    private static func loadRaw(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw Failure.osStatus(status, "SecItemCopyMatching(\(account))")
        }
        guard let data = item as? Data else {
            throw Failure.unexpectedType
        }
        return data
    }

    private static func store(privateKey: Data, account: String) throws {
        guard privateKey.count == 32 else {
            throw Failure.badSize(privateKey.count)
        }
        try storeRaw(privateKey, account: account, accessible: true)
    }

    private static func storePublic(pub: Data, account: String) throws {
        try storeRaw(pub, account: account, accessible: false)
    }

    private static func storeRaw(_ value: Data, account: String, accessible: Bool) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var attributes: [String: Any] = baseQuery
        attributes[kSecValueData as String] = value
        // AfterFirstUnlock is the most permissive accessibility we can
        // still call "secure" — required for the tunnel extension to
        // read the key at login before the user has unlocked the
        // session. Public keys use the same flag for consistency.
        attributes[kSecAttrAccessible as String] = accessible
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlock

        // Try add first; on duplicate we overwrite.
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: value]
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                update as CFDictionary,
            )
            if updateStatus == errSecSuccess { return }
            throw Failure.osStatus(updateStatus, "SecItemUpdate(\(account))")
        }
        throw Failure.osStatus(addStatus, "SecItemAdd(\(account))")
    }

    private static func deletePrivateKey(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw Failure.osStatus(status, "SecItemDelete(\(account))")
    }
}
