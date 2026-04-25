import Foundation
import InspectCore

/// Persistent identity of this Mac as far as the iOS server is concerned.
/// `clientID` is generated on first launch and stored in `UserDefaults` so
/// the device's "常に許可" decision survives across app restarts. Resetting
/// the macOS app's defaults intentionally re-prompts the user on every
/// device — that's how a designer revokes a Mac without UI on either side.
enum ClientIdentityStore {
    private static let clientIDKey = "swift-inspector.clientID"

    static func current() -> InspectMessage.ClientIdentity {
        let defaults = UserDefaults.standard
        let id: String
        if let existing = defaults.string(forKey: clientIDKey) {
            id = existing
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: clientIDKey)
        }
        return InspectMessage.ClientIdentity(clientID: id, clientName: hostName())
    }

    /// Best-effort human-readable Mac name. `Host.current().localizedName`
    /// returns the Sharing-pane name (e.g. "Yuta's MacBook Pro") which is
    /// what users recognize. Falls back to the POSIX hostname when System
    /// Configuration declines to populate it.
    private static func hostName() -> String {
        if let localized = Host.current().localizedName, !localized.isEmpty {
            return localized
        }
        return ProcessInfo.processInfo.hostName
    }
}
