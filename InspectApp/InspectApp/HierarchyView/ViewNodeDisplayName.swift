import Foundation
import InspectCore

extension ViewNode {
    /// Designer-friendly hint pulled from runtime text/title fields or the
    /// accessibility label. Returns nil when no human-readable string is
    /// available — callers should fall back to `shortClassName`.
    /// `accessibilityIdentifier` is intentionally excluded because the row
    /// already renders it as a separate badge.
    var displayName: String? {
        for key in Self.displayNameKeys {
            if let raw = properties[key] {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        if let label = accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        return nil
    }

    /// Compact form of `className` for sidebar rows: drops the leading
    /// module qualifier and the generic parameter list so
    /// `SwiftUI.VStack<TupleView<…>>` reads as `VStack`.
    var shortClassName: String {
        var name = className
        if let openIdx = name.firstIndex(of: "<") {
            name = String(name[..<openIdx])
        }
        if let dotIdx = name.lastIndex(of: ".") {
            name = String(name[name.index(after: dotIdx)...])
        }
        return name
    }

    private static let displayNameKeys = ["text", "title", "placeholder", "label"]
}
