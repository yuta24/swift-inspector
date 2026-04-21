import Foundation
import CoreGraphics

public struct ViewNode: Codable, Identifiable, Hashable, Sendable {
    public let ident: UUID
    public let className: String
    /// Frame in the parent view's bounds coordinate space. Shown in the inspector.
    /// May be undefined when the view has a non-identity transform.
    public let frame: CGRect
    /// Absolute AABB in the window's coordinate system, computed via
    /// `view.convert(view.bounds, to: window)` on the server. Used for
    /// culling and as a fallback when `frame` is degenerate.
    public let windowFrame: CGRect
    /// `view.bounds.origin` — used by the client to subtract the parent's
    /// scroll offset when recursing absolute positions (LookIn-style).
    public let boundsOrigin: CGPoint
    /// `view.bounds.size` — authoritative size of the view's native content
    /// (the solo screenshot is rendered at this size). May be nil for older
    /// servers; clients should fall back to `frame.size`.
    public let boundsSize: CGSize?
    /// Four corners of the view's bounds converted to window coordinates,
    /// in `[topLeft, topRight, bottomLeft, bottomRight]` order. Captures
    /// full 2D affine geometry so a future renderer can rotate / skew
    /// planes to match the on-screen appearance. Nil for older servers.
    public let cornersInWindow: [CGPoint]?
    public let isHidden: Bool
    public let alpha: Double
    public let backgroundColor: RGBAColor?
    public let accessibilityIdentifier: String?
    public let accessibilityLabel: String?

    // MARK: Layer properties
    public let clipsToBounds: Bool
    public let cornerRadius: Double
    public let borderWidth: Double
    public let borderColor: RGBAColor?

    // MARK: Content mode
    public let contentMode: Int?

    // MARK: Interaction
    public let isUserInteractionEnabled: Bool
    public let isEnabled: Bool?

    // MARK: Type-specific properties (e.g. UILabel.text, UIButton.title)
    public let properties: [String: String]

    /// Full screenshot including subviews (group screenshot).
    public let screenshot: Data?
    /// Screenshot of this layer only, excluding subviews (solo screenshot).
    public let soloScreenshot: Data?
    public let children: [ViewNode]

    public var id: UUID { ident }

    public init(
        ident: UUID = UUID(),
        className: String,
        frame: CGRect,
        windowFrame: CGRect? = nil,
        boundsOrigin: CGPoint = .zero,
        boundsSize: CGSize? = nil,
        cornersInWindow: [CGPoint]? = nil,
        isHidden: Bool = false,
        alpha: Double = 1.0,
        backgroundColor: RGBAColor? = nil,
        accessibilityIdentifier: String? = nil,
        accessibilityLabel: String? = nil,
        clipsToBounds: Bool = false,
        cornerRadius: Double = 0,
        borderWidth: Double = 0,
        borderColor: RGBAColor? = nil,
        contentMode: Int? = nil,
        isUserInteractionEnabled: Bool = true,
        isEnabled: Bool? = nil,
        properties: [String: String] = [:],
        screenshot: Data? = nil,
        soloScreenshot: Data? = nil,
        children: [ViewNode] = []
    ) {
        self.ident = ident
        self.className = className
        self.frame = Self.sanitize(frame)
        self.windowFrame = Self.sanitize(windowFrame ?? frame)
        self.boundsOrigin = Self.sanitize(boundsOrigin)
        self.boundsSize = boundsSize.map(Self.sanitize)
        self.cornersInWindow = cornersInWindow.map { $0.map(Self.sanitize) }
        self.isHidden = isHidden
        self.alpha = Self.sanitize(alpha)
        self.backgroundColor = backgroundColor
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.clipsToBounds = clipsToBounds
        self.cornerRadius = Self.sanitize(cornerRadius)
        self.borderWidth = Self.sanitize(borderWidth)
        self.borderColor = borderColor
        self.contentMode = contentMode
        self.isUserInteractionEnabled = isUserInteractionEnabled
        self.isEnabled = isEnabled
        self.properties = properties
        self.screenshot = screenshot
        self.soloScreenshot = soloScreenshot
        self.children = children
    }

    // Preserve backward compatibility: older servers won't include the
    // geometry fields added later (`boundsOrigin`, `boundsSize`,
    // `cornersInWindow`).
    private enum CodingKeys: String, CodingKey {
        case ident, className, frame, windowFrame, boundsOrigin, boundsSize, cornersInWindow
        case isHidden, alpha
        case backgroundColor, accessibilityIdentifier, accessibilityLabel
        case clipsToBounds, cornerRadius, borderWidth, borderColor
        case contentMode, isUserInteractionEnabled, isEnabled
        case properties, screenshot, soloScreenshot, children
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ident = try c.decode(UUID.self, forKey: .ident)
        let className = try c.decode(String.self, forKey: .className)
        let frame = try c.decode(CGRect.self, forKey: .frame)
        let windowFrame = try c.decodeIfPresent(CGRect.self, forKey: .windowFrame)
        let boundsOrigin = try c.decodeIfPresent(CGPoint.self, forKey: .boundsOrigin) ?? .zero
        let boundsSize = try c.decodeIfPresent(CGSize.self, forKey: .boundsSize)
        let cornersInWindow = try c.decodeIfPresent([CGPoint].self, forKey: .cornersInWindow)
        let isHidden = try c.decode(Bool.self, forKey: .isHidden)
        let alpha = try c.decode(Double.self, forKey: .alpha)
        let backgroundColor = try c.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor)
        let accessibilityIdentifier = try c.decodeIfPresent(String.self, forKey: .accessibilityIdentifier)
        let accessibilityLabel = try c.decodeIfPresent(String.self, forKey: .accessibilityLabel)
        let clipsToBounds = try c.decode(Bool.self, forKey: .clipsToBounds)
        let cornerRadius = try c.decode(Double.self, forKey: .cornerRadius)
        let borderWidth = try c.decode(Double.self, forKey: .borderWidth)
        let borderColor = try c.decodeIfPresent(RGBAColor.self, forKey: .borderColor)
        let contentMode = try c.decodeIfPresent(Int.self, forKey: .contentMode)
        let isUserInteractionEnabled = try c.decode(Bool.self, forKey: .isUserInteractionEnabled)
        let isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled)
        let properties = try c.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        let screenshot = try c.decodeIfPresent(Data.self, forKey: .screenshot)
        let soloScreenshot = try c.decodeIfPresent(Data.self, forKey: .soloScreenshot)
        let children = try c.decodeIfPresent([ViewNode].self, forKey: .children) ?? []

        self.init(
            ident: ident,
            className: className,
            frame: frame,
            windowFrame: windowFrame,
            boundsOrigin: boundsOrigin,
            boundsSize: boundsSize,
            cornersInWindow: cornersInWindow,
            isHidden: isHidden,
            alpha: alpha,
            backgroundColor: backgroundColor,
            accessibilityIdentifier: accessibilityIdentifier,
            accessibilityLabel: accessibilityLabel,
            clipsToBounds: clipsToBounds,
            cornerRadius: cornerRadius,
            borderWidth: borderWidth,
            borderColor: borderColor,
            contentMode: contentMode,
            isUserInteractionEnabled: isUserInteractionEnabled,
            isEnabled: isEnabled,
            properties: properties,
            screenshot: screenshot,
            soloScreenshot: soloScreenshot,
            children: children
        )
    }

    private static func sanitize(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func sanitize(_ rect: CGRect) -> CGRect {
        CGRect(
            x: sanitize(Double(rect.origin.x)),
            y: sanitize(Double(rect.origin.y)),
            width: max(0, sanitize(Double(rect.size.width))),
            height: max(0, sanitize(Double(rect.size.height)))
        )
    }

    private static func sanitize(_ point: CGPoint) -> CGPoint {
        CGPoint(x: sanitize(Double(point.x)), y: sanitize(Double(point.y)))
    }

    private static func sanitize(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(0, sanitize(Double(size.width))),
            height: max(0, sanitize(Double(size.height)))
        )
    }

    /// Human-readable content mode name.
    public var contentModeName: String? {
        guard let raw = contentMode else { return nil }
        switch raw {
        case 0: return "scaleToFill"
        case 1: return "scaleAspectFit"
        case 2: return "scaleAspectFill"
        case 3: return "redraw"
        case 4: return "center"
        case 5: return "top"
        case 6: return "bottom"
        case 7: return "left"
        case 8: return "right"
        case 9: return "topLeft"
        case 10: return "topRight"
        case 11: return "bottomLeft"
        case 12: return "bottomRight"
        default: return "unknown(\(raw))"
        }
    }
}
