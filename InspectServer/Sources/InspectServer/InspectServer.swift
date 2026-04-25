#if DEBUG || SWIFT_INSPECTOR_ENABLED
import Foundation

public enum InspectServer {
    private static var listener: InspectListener?

    public static func start(serviceName: String? = nil) {
        if listener != nil { return }
        let instance = InspectListener(serviceName: serviceName)
        do {
            try instance.start()
            listener = instance
        } catch {
            assertionFailure("InspectServer failed to start: \(error)")
        }
    }

    public static func stop() {
        listener?.stop()
        listener = nil
    }

    /// Clears every remembered Mac so the next connection request will
    /// prompt the user again. Wire this to a "信頼する Mac をリセット"
    /// action in your debug menu when a designer mistakenly approves the
    /// wrong host. Works regardless of whether the listener is currently
    /// running — the trusted list lives in `UserDefaults`, not in
    /// listener state.
    public static func forgetAllPairedClients() {
        PairingStore().revokeAll()
    }
}
#endif
