#if DEBUG || SWIFT_INSPECTOR_ENABLED
import Foundation

/// Entry point for the inspector server embedded in the host iOS app.
///
/// The whole type compiles to nothing unless `DEBUG` or
/// `SWIFT_INSPECTOR_ENABLED` is defined, so the inspection code never ships
/// in a release binary that doesn't opt in. Always wrap calls in a
/// `#if DEBUG || SWIFT_INSPECTOR_ENABLED` guard at the call site, otherwise
/// release builds fail with "Cannot find 'InspectServer' in scope".
///
/// ## Typical use
///
/// ```swift
/// import InspectServer
///
/// @main
/// struct MyApp: App {
///     init() {
///         #if DEBUG || SWIFT_INSPECTOR_ENABLED
///         InspectServer.start()
///         #endif
///     }
///     var body: some Scene { /* ... */ }
/// }
/// ```
///
/// ## Required Info.plist keys
///
/// - `NSLocalNetworkUsageDescription`: a short reason string shown in the
///   Local Network permission prompt the first time the listener starts.
///   Without this key, ``start(serviceName:)`` succeeds but the OS blocks
///   the listener from accepting connections.
///
/// `NSBonjourServices` is **not** required on the publishing side — that
/// declaration only gates `NWBrowser` (the macOS client side), and macOS
/// itself does not enforce it.
public enum InspectServer {
    private static var listener: InspectListener?

    /// Starts publishing the Bonjour service and accepting client
    /// connections. Idempotent — calling it again while already running is
    /// a no-op.
    ///
    /// Listener startup errors are surfaced as `assertionFailure` so they
    /// crash debug builds loudly and are silently absorbed in production
    /// internal builds. If you need to react to a startup failure, file an
    /// issue describing the use case so we can add a proper completion
    /// signal.
    ///
    /// - Parameter serviceName: Bonjour instance name shown in the macOS
    ///   client's device list. Defaults to the device's user-assigned name.
    ///   Override when you want a stable identifier across devices (e.g.
    ///   "QA iPhone — Checkout flow").
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

    /// Tears down the listener and disconnects every active client. Safe to
    /// call when not running.
    public static func stop() {
        listener?.stop()
        listener = nil
    }

    /// Forgets every Mac that was previously approved on the device-side
    /// pairing prompt so the next connection request from each one prompts
    /// the user again.
    ///
    /// Wire this to a "信頼する Mac をリセット" action in your debug menu
    /// for the case where a designer mistakenly approves the wrong host.
    /// Works regardless of whether the listener is currently running — the
    /// trusted list lives in `UserDefaults`, not in listener state.
    public static func forgetAllPairedClients() {
        PairingStore().revokeAll()
    }
}
#endif
