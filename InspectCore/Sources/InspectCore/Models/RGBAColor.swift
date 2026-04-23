import Foundation
import CoreGraphics

public struct RGBAColor: Codable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = Self.sanitize(red)
        self.green = Self.sanitize(green)
        self.blue = Self.sanitize(blue)
        self.alpha = Self.sanitize(alpha)
    }

    private static func sanitize(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    /// sRGB hex in `#RRGGBB` form, dropping the alpha channel. Components are
    /// clamped to `[0, 1]` before byte-quantisation so wide-gamut colors fall
    /// back to the closest sRGB representation.
    public var hexRGB: String {
        String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// sRGB hex in `#RRGGBBAA` form. Prefer this when the view has
    /// `alpha < 1.0` — designers need the alpha channel to match Figma.
    public var hexRGBA: String {
        String(format: "#%02X%02X%02X%02X", byte(red), byte(green), byte(blue), byte(alpha))
    }

    /// UIKit literal, e.g. `UIColor(red: 0.12, green: 0.34, blue: 0.56, alpha: 1.00)`.
    public var uiColorLiteral: String {
        String(
            format: "UIColor(red: %.3f, green: %.3f, blue: %.3f, alpha: %.3f)",
            red, green, blue, alpha
        )
    }

    /// SwiftUI literal in the same shape.
    public var swiftUIColorLiteral: String {
        String(
            format: "Color(red: %.3f, green: %.3f, blue: %.3f).opacity(%.3f)",
            red, green, blue, alpha
        )
    }

    private func byte(_ channel: Double) -> Int {
        let clamped = min(max(channel, 0), 1)
        return Int((clamped * 255).rounded())
    }
}

#if canImport(UIKit)
import UIKit

public extension RGBAColor {
    init?(uiColor: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return nil
        }
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }
}
#endif

#if canImport(AppKit)
import AppKit

public extension RGBAColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif

#if canImport(SwiftUI)
import SwiftUI

public extension RGBAColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
#endif
