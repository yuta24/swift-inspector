#if (DEBUG || SWIFT_INSPECTOR_ENABLED) && canImport(UIKit)
import UIKit
import Foundation

@MainActor
final class ViewIdentRegistry {
    static let shared = ViewIdentRegistry()

    /// Pair a UUID with a *weak* reference to the originating view so an
    /// address-reuse after dealloc cannot return a stale ident. UIViews
    /// are short-lived under SwiftUI / UICollectionView reuse, and a
    /// fresh allocation that happens to land at the same address as a
    /// previously-registered view would otherwise inherit the old UUID
    /// and cause the highlight overlay to land on the wrong view.
    private struct Entry {
        weak var view: UIView?
        let ident: UUID
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    private init() {}

    func register(view: UIView, ident: UUID) {
        entries[ObjectIdentifier(view)] = Entry(view: view, ident: ident)
    }

    func ident(for view: UIView) -> UUID? {
        let key = ObjectIdentifier(view)
        guard let entry = entries[key] else { return nil }
        // The weak ref auto-nils when the original view deallocs; if a new
        // view took over the same address since registration, the slot
        // still has the stale entry but `entry.view !== view` rejects it.
        // Drop the dead slot opportunistically so a long-lived session
        // (live mode + heavy view churn) doesn't accumulate dead entries
        // until the next `clear()` at the start of a capture.
        guard entry.view === view else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.ident
    }

    func clear() {
        entries.removeAll()
    }
}
#endif
