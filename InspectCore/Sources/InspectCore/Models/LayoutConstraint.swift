import Foundation

/// A snapshot of a single `NSLayoutConstraint` between two anchors.
public struct LayoutConstraint: Codable, Hashable, Sendable {
    /// One end of the constraint — either a view or a layout guide.
    public struct Anchor: Codable, Hashable, Sendable {
        /// UUID of the owning view. For a UILayoutGuide this is the UUID of
        /// the guide's `owningView`. Nil if the anchor couldn't be resolved
        /// to a node in this snapshot (e.g. the item is a sibling outside
        /// the captured subtree, or its owning view was released before
        /// registration). For width/height constraints the anchor that has
        /// no counterpart is represented by `LayoutConstraint.second == nil`
        /// rather than a nil `ownerID` here.
        public let ownerID: UUID?
        /// Human-readable item description: the class name, or
        /// `"UIView.safeAreaLayoutGuide"` for layout guides.
        public let description: String
        /// True when the anchor refers to a `UILayoutGuide`, false for a
        /// `UIView`.
        public let isLayoutGuide: Bool
        /// `NSLayoutConstraint.Attribute` rawValue. `.notAnAttribute` (0)
        /// means there is no second anchor (e.g. a pure constant width).
        public let attribute: Int

        public init(
            ownerID: UUID?,
            description: String,
            isLayoutGuide: Bool,
            attribute: Int
        ) {
            self.ownerID = ownerID
            self.description = description
            self.isLayoutGuide = isLayoutGuide
            self.attribute = attribute
        }
    }

    /// Optional identifier set via `constraint.identifier`.
    public let identifier: String?
    public let first: Anchor
    /// `nil` when `secondAttribute == .notAnAttribute` (e.g. `view.widthAnchor.constraint(equalToConstant: 44)`).
    public let second: Anchor?
    /// `NSLayoutConstraint.Relation` rawValue: -1 / 0 / 1 for lessThanOrEqual / equal / greaterThanOrEqual.
    public let relation: Int
    public let multiplier: Double
    public let constant: Double
    /// `UILayoutPriority` rawValue (0...1000).
    public let priority: Float
    public let isActive: Bool

    public init(
        identifier: String?,
        first: Anchor,
        second: Anchor?,
        relation: Int,
        multiplier: Double,
        constant: Double,
        priority: Float,
        isActive: Bool
    ) {
        self.identifier = identifier
        self.first = first
        self.second = second
        self.relation = relation
        self.multiplier = Self.sanitize(multiplier)
        self.constant = Self.sanitize(constant)
        self.priority = priority.isFinite ? priority : 0
        self.isActive = isActive
    }

    private static func sanitize(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}

extension LayoutConstraint {
    /// Human-readable attribute name for an `NSLayoutConstraint.Attribute`
    /// rawValue. Kept as a pure function here so the macOS client doesn't
    /// need to link UIKit.
    public static func attributeName(_ raw: Int) -> String {
        switch raw {
        case 0: return "notAnAttribute"
        case 1: return "left"
        case 2: return "right"
        case 3: return "top"
        case 4: return "bottom"
        case 5: return "leading"
        case 6: return "trailing"
        case 7: return "width"
        case 8: return "height"
        case 9: return "centerX"
        case 10: return "centerY"
        case 11: return "lastBaseline"
        case 12: return "firstBaseline"
        case 13: return "leftMargin"
        case 14: return "rightMargin"
        case 15: return "topMargin"
        case 16: return "bottomMargin"
        case 17: return "leadingMargin"
        case 18: return "trailingMargin"
        case 19: return "centerXWithinMargins"
        case 20: return "centerYWithinMargins"
        default: return "attr(\(raw))"
        }
    }

    public static func relationSymbol(_ raw: Int) -> String {
        switch raw {
        case -1: return "≤"
        case 0: return "="
        case 1: return "≥"
        default: return "?"
        }
    }
}
