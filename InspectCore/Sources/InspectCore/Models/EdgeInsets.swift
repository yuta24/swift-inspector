import Foundation

/// Four-sided inset values, used to ship `UIView.safeAreaInsets` to the
/// macOS client without leaking UIKit into the shared core. Recorded only
/// for `UIWindow` and the root view of each `UIViewController` — for
/// arbitrary subviews the value would be either zero or inherited from a
/// containing scroll view, neither of which matters to the inspector.
public struct EdgeInsets: Codable, Hashable, Sendable {
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = Self.sanitize(top)
        self.left = Self.sanitize(left)
        self.bottom = Self.sanitize(bottom)
        self.right = Self.sanitize(right)
    }

    public static let zero = EdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    private static func sanitize(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
