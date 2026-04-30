#if DEBUG || SWIFT_INSPECTOR_ENABLED
import Foundation
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "server")

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
    /// Serializes access to the `listener` slot so two threads racing on
    /// `start()` / `stop()` can't both observe `nil` and install duplicate
    /// listeners (which would publish the same Bonjour name twice and
    /// orphan one of them). Plain `static var` access is not atomic.
    private static let stateLock = NSLock()
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
        stateLock.lock()
        defer { stateLock.unlock() }
        if listener != nil { return }
        let instance = InspectListener(serviceName: serviceName)
        do {
            // Hold the lock through `instance.start()` so a concurrent
            // `stop()` cannot interleave between the slot assignment and
            // the actual socket bind — otherwise `stop()` would capture
            // and tear down an instance whose `NWListener` hasn't been
            // installed yet, then this thread would happily install one
            // and leave it orphaned (publishing Bonjour while
            // `InspectServer.listener == nil`). `instance.start()` does
            // a quick `queue.sync` to install the listener; it does not
            // re-enter `InspectServer`, so there's no deadlock risk.
            try instance.start()
            listener = instance
        } catch {
            assertionFailure("InspectServer failed to start: \(error)")
        }
    }

    /// Tears down the listener and disconnects every active client. Safe to
    /// call when not running.
    public static func stop() {
        stateLock.lock()
        let captured = listener
        listener = nil
        stateLock.unlock()
        // Tear the listener down outside the lock — `InspectListener.stop`
        // does its own internal queue.sync and we don't want to hold two
        // locks at once.
        captured?.stop()
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

    /// Displays an on-device overlay with the IP address and port the
    /// macOS client should dial. Used when Bonjour discovery fails
    /// (corp Wi-Fi client isolation, guest networks, locked-down
    /// conference rooms): the user reads `host:port` off the screen
    /// and types it into AppInspector's "Connect by IP" sheet.
    ///
    /// Returns `false` and skips the overlay when the listener isn't
    /// running, when no usable network interface was found, or when
    /// the call site can't reach a UIWindowScene (extension contexts,
    /// very early launch). Tap-anywhere-to-dismiss; the host app does
    /// not need to provide any view-controller hook.
    ///
    /// Wire this to a "接続情報を表示" / "Show connection info" entry
    /// in your debug menu.
    @MainActor
    @discardableResult
    public static func presentConnectionInfo() -> Bool {
        #if canImport(UIKit)
        stateLock.lock()
        let captured = listener
        stateLock.unlock()
        guard let captured, let port = captured.boundPort else {
            // Logged at warning level so a debug-menu user wiring this
            // up sees a meaningful trace in Console.app instead of a
            // silent no-op when they forgot to call `start()` first.
            logger.warning("presentConnectionInfo: listener is not running; call InspectServer.start() first")
            return false
        }
        guard let address = LocalIPLookup.bestIPv4Address() else {
            logger.warning("presentConnectionInfo: no usable IPv4 interface (offline / cellular-only / link-local)")
            return false
        }
        ConnectionInfoOverlay.show(host: address, port: port)
        return true
        #else
        return false
        #endif
    }

    /// Programmatic dismissal of the connection-info overlay. The
    /// overlay also auto-dismisses on background tap, so this is
    /// only needed when the host app wants to clear it from a custom
    /// affordance (e.g. a debug-menu close button).
    @MainActor
    public static func dismissConnectionInfo() {
        #if canImport(UIKit)
        ConnectionInfoOverlay.hide()
        #endif
    }
}
#endif
