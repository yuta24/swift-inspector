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
