import Foundation

/// Typography attributes extracted from a text-bearing view (UILabel /
/// UIButton.titleLabel / UITextField / UITextView / CATextLayer). Added so the
/// macOS client can surface font and color details for design review without
/// having to parse the generic `properties` string map.
///
/// All fields are optional — older servers won't ship them, and individual
/// fields may be unavailable (e.g. `weight` can't always be introspected from
/// an arbitrary `UIFont` because Apple exposes it only through the descriptor
/// attributes dictionary).
public struct Typography: Codable, Hashable, Sendable {
    /// PostScript font name, e.g. `"SFUI-Semibold"`.
    public let fontName: String
    /// Family name, e.g. `"SF UI"` — useful when the designer cares about the
    /// font family rather than the concrete face.
    public let familyName: String?
    /// Point size as drawn.
    public let pointSize: Double
    /// UIFont.Weight raw value (-1.0 regular range to 1.0). Nil when the font
    /// descriptor doesn't advertise a standard weight.
    public let weight: Double?
    /// Human-readable weight name ("regular", "semibold", "bold", ...). Derived
    /// from `weight` on the server so the client doesn't need the mapping.
    public let weightName: String?
    /// `true` when the font's symbolic traits include `.traitBold`.
    public let isBold: Bool
    /// `true` when the font's symbolic traits include `.traitItalic`.
    public let isItalic: Bool
    /// Foreground text color.
    public let textColor: RGBAColor?
    /// Text alignment: `"left"`, `"center"`, `"right"`, `"justified"`, `"natural"`.
    public let alignment: String?
    /// `numberOfLines` for UILabel; nil for other sources.
    public let numberOfLines: Int?
    /// Font `lineHeight` (ascender + |descender| + leading) — the vertical
    /// space one line occupies. Useful for matching Figma "line height" specs.
    public let lineHeight: Double?
    /// Font `ascender`.
    public let ascender: Double?
    /// Font `descender` (negative).
    public let descender: Double?

    public init(
        fontName: String,
        familyName: String? = nil,
        pointSize: Double,
        weight: Double? = nil,
        weightName: String? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        textColor: RGBAColor? = nil,
        alignment: String? = nil,
        numberOfLines: Int? = nil,
        lineHeight: Double? = nil,
        ascender: Double? = nil,
        descender: Double? = nil
    ) {
        self.fontName = fontName
        self.familyName = familyName
        self.pointSize = Self.sanitize(pointSize)
        self.weight = weight.map(Self.sanitize)
        self.weightName = weightName
        self.isBold = isBold
        self.isItalic = isItalic
        self.textColor = textColor
        self.alignment = alignment
        self.numberOfLines = numberOfLines
        self.lineHeight = lineHeight.map(Self.sanitize)
        self.ascender = ascender.map(Self.sanitize)
        self.descender = descender.map(Self.sanitize)
    }

    private static func sanitize(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
