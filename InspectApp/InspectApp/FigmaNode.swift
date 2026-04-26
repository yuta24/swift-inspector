import Foundation
import CoreGraphics

/// A subset of the Figma `Node` REST type we actually need to compare
/// against an iOS `ViewNode`. Decoded directly from the raw JSON returned
/// by `GET /v1/files/:key/nodes` — irrelevant fields (component refs,
/// auto-layout settings, prototype links) are dropped at decode time.
///
/// This is deliberately a flat-ish model: the only nested type is
/// `style`, which only appears on TEXT nodes. Keeping the surface small
/// makes the diff logic easier to reason about than wrangling the full
/// generic Figma JSON.
struct FigmaNode: Decodable, Equatable {
    let id: String
    let name: String
    let type: String
    let absoluteBoundingBox: BoundingBox?
    let cornerRadius: Double?
    /// Per-corner radii (`[topLeft, topRight, bottomRight, bottomLeft]`)
    /// when the layer uses non-uniform corners. Falls back to
    /// `cornerRadius` for the uniform case.
    let rectangleCornerRadii: [Double]?
    let fills: [Paint]?
    let strokes: [Paint]?
    let strokeWeight: Double?
    let style: TextStyle?
    let characters: String?
    let children: [FigmaNode]

    struct BoundingBox: Decodable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    /// Single fill or stroke entry. Figma supports gradients and image
    /// fills too; the inspector only diffs SOLID values for now and
    /// surfaces other types as "Gradient" / "Image" without a colour
    /// comparison.
    struct Paint: Decodable, Equatable {
        let type: String
        let color: Color?
        /// Top-level opacity multiplier. Combined with `color.a` to
        /// produce the effective alpha. Defaults to 1 when missing.
        let opacity: Double?
        /// `false` for hidden fills (Figma keeps invisible layers in the
        /// fill list). Default `true`.
        let visible: Bool?
    }

    struct Color: Decodable, Equatable {
        let r: Double
        let g: Double
        let b: Double
        let a: Double
    }

    /// Typography subset surfaced on TEXT nodes. Names match Figma's
    /// API casing — they're sent verbatim to the diff layer.
    struct TextStyle: Decodable, Equatable {
        let fontFamily: String?
        let fontPostScriptName: String?
        let fontWeight: Double?
        let fontSize: Double?
        let lineHeightPx: Double?
        let lineHeightPercent: Double?
        let lineHeightUnit: String?
        let letterSpacing: Double?
        let textAlignHorizontal: String?
    }

    /// Convenience for downstream code that doesn't care which corner-
    /// radius API path Figma used. Returns the uniform value, or — when
    /// per-corner values are set — the largest of the four (lossy but
    /// matches how UIKit's `cornerRadius` would visually appear).
    var effectiveCornerRadius: Double? {
        if let radii = rectangleCornerRadii, !radii.isEmpty {
            return radii.max()
        }
        return cornerRadius
    }

    /// First visible SOLID fill, if any. Used as the comparable
    /// "background colour" against `ViewNode.backgroundColor`.
    var primarySolidFill: Paint? {
        fills?.first { $0.type == "SOLID" && $0.visible != false }
    }

    /// Pre-order flattening of this subtree — handy for matchers that
    /// need to look up layers by id or name without walking the tree on
    /// every query.
    func flattened() -> [FigmaNode] {
        var out: [FigmaNode] = [self]
        for child in children {
            out.append(contentsOf: child.flattened())
        }
        return out
    }

    // Tolerant decoding: every field except id / name / type is
    // optional, and `children` defaults to empty (LEAF nodes simply
    // don't include the key).
    private enum CodingKeys: String, CodingKey {
        case id, name, type
        case absoluteBoundingBox, cornerRadius, rectangleCornerRadii
        case fills, strokes, strokeWeight
        case style, characters, children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decode(String.self, forKey: .type)
        self.absoluteBoundingBox = try c.decodeIfPresent(BoundingBox.self, forKey: .absoluteBoundingBox)
        self.cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius)
        self.rectangleCornerRadii = try c.decodeIfPresent([Double].self, forKey: .rectangleCornerRadii)
        self.fills = try c.decodeIfPresent([Paint].self, forKey: .fills)
        self.strokes = try c.decodeIfPresent([Paint].self, forKey: .strokes)
        self.strokeWeight = try c.decodeIfPresent(Double.self, forKey: .strokeWeight)
        self.style = try c.decodeIfPresent(TextStyle.self, forKey: .style)
        self.characters = try c.decodeIfPresent(String.self, forKey: .characters)
        self.children = try c.decodeIfPresent([FigmaNode].self, forKey: .children) ?? []
    }

    /// Memberwise initialiser for tests / fixtures. Production code
    /// always goes through the decoder.
    init(
        id: String,
        name: String,
        type: String,
        absoluteBoundingBox: BoundingBox? = nil,
        cornerRadius: Double? = nil,
        rectangleCornerRadii: [Double]? = nil,
        fills: [Paint]? = nil,
        strokes: [Paint]? = nil,
        strokeWeight: Double? = nil,
        style: TextStyle? = nil,
        characters: String? = nil,
        children: [FigmaNode] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.absoluteBoundingBox = absoluteBoundingBox
        self.cornerRadius = cornerRadius
        self.rectangleCornerRadii = rectangleCornerRadii
        self.fills = fills
        self.strokes = strokes
        self.strokeWeight = strokeWeight
        self.style = style
        self.characters = characters
        self.children = children
    }
}
