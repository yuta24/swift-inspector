#if (DEBUG || SWIFT_INSPECTOR_ENABLED) && canImport(UIKit)
import UIKit
import Foundation

@MainActor
final class ViewIdentRegistry {
    static let shared = ViewIdentRegistry()

    private var viewToIdent: [ObjectIdentifier: UUID] = [:]

    private init() {}

    func register(view: UIView, ident: UUID) {
        viewToIdent[ObjectIdentifier(view)] = ident
    }

    func ident(for view: UIView) -> UUID? {
        viewToIdent[ObjectIdentifier(view)]
    }

    func clear() {
        viewToIdent.removeAll()
    }
}
#endif
