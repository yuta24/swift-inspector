import Foundation
import CoreGraphics

public struct ViewNode: Codable, Identifiable, Hashable, Sendable {
    public let ident: UUID
    public let className: String
    public let frame: CGRect
    public let isHidden: Bool
    public let alpha: Double
    public let backgroundColor: RGBAColor?
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
        screenshot: Data? = nil,
        soloScreenshot: Data? = nil,
        children: [ViewNode] = []
    ) {
        self.ident = ident
        self.className = className
        self.frame = frame
        self.isHidden = isHidden
        self.alpha = alpha
        self.backgroundColor = backgroundColor
        self.screenshot = screenshot
        self.soloScreenshot = soloScreenshot
        self.children = children
    }
}
