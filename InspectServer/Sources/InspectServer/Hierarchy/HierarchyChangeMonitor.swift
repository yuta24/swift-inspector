#if DEBUG && canImport(UIKit)
import UIKit
import os.log
import QuartzCore

private let logger = Logger(subsystem: "swift-inspector", category: "monitor")

/// Detects layout changes in the host app and fires a callback so the listener
/// can push a fresh hierarchy snapshot. Runs on the main run loop rather than
/// swizzling UIKit methods — that keeps detection uniform across UIKit and
/// SwiftUI-rendered content, which both commit to CoreAnimation on the same
/// run loop.
///
/// Each `.beforeWaiting` tick we compute a cheap fingerprint (FNV-1a over
/// frame/alpha/isHidden/subview count for every attached view) and only fire
/// when it differs from the previous tick. Rate-limited by `minIntervalSec`
/// so animating apps don't get runaway capture costs.
@MainActor
final class HierarchyChangeMonitor {
    private var observer: CFRunLoopObserver?
    private var lastFingerprint: UInt64 = 0
    private var lastFireAt: CFAbsoluteTime = 0
    private var minIntervalSec: TimeInterval = 0.016
    private var onChanged: (() -> Void)?
    /// Always fire the first tick after `start` so the client gets an initial
    /// snapshot without having to also issue a separate `requestHierarchy`.
    private var hasFiredInitial: Bool = false

    func start(minIntervalSec: TimeInterval, onChanged: @escaping () -> Void) {
        stop()
        self.minIntervalSec = minIntervalSec
        self.onChanged = onChanged
        self.lastFingerprint = 0
        self.lastFireAt = 0
        self.hasFiredInitial = false

        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true, // repeats
            0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        logger.info("HierarchyChangeMonitor started (minInterval=\(minIntervalSec, privacy: .public)s)")
    }

    func stop() {
        guard let observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .defaultMode)
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = nil
        self.onChanged = nil
        logger.info("HierarchyChangeMonitor stopped")
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        if hasFiredInitial, now - lastFireAt < minIntervalSec {
            return
        }
        let fp = computeFingerprint()
        if hasFiredInitial, fp == lastFingerprint {
            return
        }
        lastFingerprint = fp
        lastFireAt = now
        hasFiredInitial = true
        onChanged?()
    }

    // MARK: - Fingerprint

    private func computeFingerprint() -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a offset basis
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        for window in windows {
            mix(UInt64(window.windowLevel.rawValue.bitPattern), into: &hash)
            hashView(window, into: &hash)
        }
        return hash
    }

    private func hashView(_ view: UIView, into hash: inout UInt64) {
        // Quantize frame values to 0.1pt resolution so imperceptible float
        // jitter doesn't cause spurious pushes. Origin/size both contribute.
        mix(quantize(view.frame.origin.x), into: &hash)
        mix(quantize(view.frame.origin.y), into: &hash)
        mix(quantize(view.frame.size.width), into: &hash)
        mix(quantize(view.frame.size.height), into: &hash)
        // Scroll offsets matter visually; include `bounds.origin`.
        mix(quantize(view.bounds.origin.x), into: &hash)
        mix(quantize(view.bounds.origin.y), into: &hash)
        mix(view.isHidden ? 1 : 0, into: &hash)
        mix(quantize(view.alpha, scale: 1000), into: &hash)
        // Subview count guards against structure changes that happen to
        // preserve every individual subview's own hash.
        mix(UInt64(view.subviews.count), into: &hash)
        for subview in view.subviews {
            hashView(subview, into: &hash)
        }
    }

    private func quantize(_ value: CGFloat, scale: CGFloat = 10) -> UInt64 {
        // Non-finite values (NaN, ±∞) show up in frames during transforms or
        // before layout resolves. Mix the raw bit pattern so distinct non-finite
        // values still contribute distinctly, without crashing the Int64 cast.
        guard value.isFinite else {
            return Double(value).bitPattern
        }
        return UInt64(bitPattern: Int64((value * scale).rounded()))
    }

    private func mix(_ value: UInt64, into hash: inout UInt64) {
        hash ^= value
        hash &*= 0x100000001b3 // FNV-1a prime
    }
}
#endif
