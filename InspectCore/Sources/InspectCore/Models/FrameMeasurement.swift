import Foundation
import CoreGraphics

/// Pair-wise geometric measurement between two axis-aligned rectangles in
/// a shared coordinate space (typically each view's `windowFrame`). Pure
/// value type — safe to compute on either the client or server.
public struct FrameMeasurement: Equatable, Sendable {
    /// Signed horizontal gap between the inner edges.
    /// Positive when `target` is strictly to the right of `reference`,
    /// negative when strictly to the left, zero when the two rectangles
    /// overlap on the x axis.
    public let horizontalGap: CGFloat

    /// Signed vertical gap between the inner edges.
    /// Positive when `target` is strictly below `reference`,
    /// negative when strictly above, zero when the two rectangles
    /// overlap on the y axis.
    public let verticalGap: CGFloat

    /// Euclidean distance between the two rectangles' centers.
    public let centerDistance: CGFloat

    /// Difference vector between centers (target - reference).
    public let centerDelta: CGSize

    /// Relationship between the two rectangles — useful to caption the
    /// measurement ("B is inside A", "overlap", "non-intersecting").
    public let relationship: Relationship

    public enum Relationship: String, Sendable, Equatable {
        /// Rectangles do not touch on either axis.
        case disjoint
        /// Rectangles overlap but neither fully contains the other.
        case overlapping
        /// `target` is entirely inside `reference`.
        case targetInsideReference
        /// `reference` is entirely inside `target`.
        case referenceInsideTarget
        /// The two rectangles are identical.
        case identical
    }

    /// Computes the measurement from `reference` to `target`. Both rects
    /// must be in the same coordinate space (e.g. window coordinates).
    public init(reference: CGRect, target: CGRect) {
        let refCenter = CGPoint(x: reference.midX, y: reference.midY)
        let tgtCenter = CGPoint(x: target.midX, y: target.midY)
        self.centerDelta = CGSize(
            width: tgtCenter.x - refCenter.x,
            height: tgtCenter.y - refCenter.y
        )
        self.centerDistance = hypot(centerDelta.width, centerDelta.height)
        self.horizontalGap = Self.signedGap(
            referenceMin: reference.minX, referenceMax: reference.maxX,
            targetMin: target.minX, targetMax: target.maxX
        )
        self.verticalGap = Self.signedGap(
            referenceMin: reference.minY, referenceMax: reference.maxY,
            targetMin: target.minY, targetMax: target.maxY
        )
        self.relationship = Self.relationship(reference: reference, target: target)
    }

    /// Signed distance between two 1D intervals. Positive when `target` is
    /// strictly after `reference`, negative when strictly before, zero when
    /// they overlap.
    private static func signedGap(
        referenceMin a0: CGFloat, referenceMax a1: CGFloat,
        targetMin b0: CGFloat, targetMax b1: CGFloat
    ) -> CGFloat {
        if b0 >= a1 { return b0 - a1 }
        if b1 <= a0 { return b1 - a0 } // negative
        return 0
    }

    private static func relationship(reference: CGRect, target: CGRect) -> Relationship {
        if reference == target { return .identical }
        if reference.contains(target) { return .targetInsideReference }
        if target.contains(reference) { return .referenceInsideTarget }
        if reference.intersects(target) { return .overlapping }
        return .disjoint
    }
}
