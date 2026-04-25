#if DEBUG || SWIFT_INSPECTOR_ENABLED
import Foundation

/// Persists the set of macOS client IDs the user has chosen to "always allow".
/// Stored in `UserDefaults.standard` so the data lives inside the host app's
/// container — uninstalling the host app naturally clears the trusted list,
/// which matches the user's mental model ("the device forgot my Mac").
struct PairingStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "swift-inspector.trustedClients") {
        self.defaults = defaults
        self.key = key
    }

    func isTrusted(clientID: String) -> Bool {
        trustedIDs().contains(clientID)
    }

    func trust(clientID: String) {
        var ids = trustedIDs()
        guard !ids.contains(clientID) else { return }
        ids.insert(clientID)
        defaults.set(Array(ids), forKey: key)
    }

    func revoke(clientID: String) {
        var ids = trustedIDs()
        guard ids.remove(clientID) != nil else { return }
        defaults.set(Array(ids), forKey: key)
    }

    func revokeAll() {
        defaults.removeObject(forKey: key)
    }

    private func trustedIDs() -> Set<String> {
        let raw = defaults.array(forKey: key) as? [String] ?? []
        return Set(raw)
    }
}
#endif
