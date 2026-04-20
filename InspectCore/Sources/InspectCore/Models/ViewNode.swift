import Foundation
import CoreGraphics

public struct ViewNode: Codable, Identifiable, Hashable, Sendable {
    public let ident: UUID
    public let className: String
    public let frame: CGRect
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
