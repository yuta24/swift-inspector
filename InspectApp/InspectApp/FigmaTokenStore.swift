import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "figma-token")

/// Keychain-backed storage for the Figma Personal Access Token. Kept out of
/// `UserDefaults` because the PAT is a write-capable credential — anyone who
/// reads the defaults file (e.g. via Time Machine, a leaked profile, or a
/// compromised IDE) would inherit the user's Figma access.
///
/// Stored as a generic password under `kSecAttrService = "swift-inspector.figma.pat"`
/// so the entry is namespaced and easy to spot in Keychain Access. Items are
/// scoped with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, which matches
/// how a user-typed token would be expected to behave: usable only while the
/// Mac is unlocked, never synced to iCloud Keychain.
enum FigmaTokenStore {
    private static let service = "swift-inspector.figma.pat"
    private static let account = "default"

    /// Saves `token`, replacing any previous value. Pass an empty (or
    /// whitespace-only) string to delete the entry instead — saving ""
    /// would otherwise leave a useless stub in Keychain. Returns `true` on
    /// success and `false` when Keychain refuses the write — the caller must
    /// surface that failure rather than treat it as a successful save.
    /// `errSecInteractionNotAllowed` (Keychain locked at the moment of the
    /// call) is the realistic failure mode worth flagging.
    @discardableResult
    static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete()
            return true
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update only writes the data — passing kSecAttrAccessible to
        // SecItemUpdate is rejected with errSecParam on some macOS releases.
        // The accessibility class is fixed at first-add time below.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("FigmaTokenStore.save SecItemAdd failed: OSStatus=\(addStatus)")
                return false
            }
            return true
        default:
            // Anything else (Keychain locked, ACL refused, daemon unhappy)
            // means the previous token is still in place — surface the
            // failure so the UI doesn't tell the user we saved when we
            // didn't.
            logger.error("FigmaTokenStore.save SecItemUpdate failed: OSStatus=\(updateStatus)")
            return false
        }
    }

    /// Returns the saved token, or nil if none has been entered (or the
    /// Keychain entry has been removed externally).
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// Removes the saved token. No-op when nothing is stored.
    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
