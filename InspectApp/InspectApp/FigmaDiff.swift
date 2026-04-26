import Foundation
import CoreGraphics
import InspectCore

/// Per-attribute spec-vs-implementation diff between an iOS `ViewNode`
/// and its matched Figma layer. Each `Item` carries both the design
/// value and the runtime value plus a coarse status (`match` / `differ`
/// / `unavailable`) so the inspector can render a green/red dot without
/// re-computing the comparison.
///
/// Tolerances are tuned for designer-facing review: sub-pixel float
/// noise (e.g. cornerRadius 12 vs 12.000001) doesn't pop a warning, but
/// any visible mismatch does.
struct FigmaDiff: Equatable {
    enum Status: Equatable {
        case match
        case differ
        /// One side doesn't expose this attribute (e.g. Figma has no
        /// equivalent of `clipsToBounds`, iOS doesn't ship gradient
        /// fills via the inspector wire format). UI shows these greyed
        /// out rather than red — they aren't actionable diffs.
        case unavailable
    }

    enum Category: String, Equatable, CaseIterable {
        case size
        case fill
        case cornerRadius
        case typography
    }

    struct Item: Equatable {
        let category: Category
        let label: String
        /// Designer-readable Figma value (`"#1F8FFFFF"`, `"17pt"`, ...).
        let figma: String?
        /// Designer-readable iOS value.
        let device: String?
        let status: Status
    }

    let items: [Item]

    var hasDifference: Bool {
        items.contains { $0.status == .differ }
    }

    /// Filtered view for "show me only what's wrong". Empty when nothing
    /// differs, which lets the inspector render an "all clear" affordance
    /// instead of an empty list.
    var differingItems: [Item] {
        items.filter { $0.status == .differ }
    }

    static let widthHeightTolerance: Double = 0.5
    static let radiusTolerance: Double = 0.5
    static let fontSizeTolerance: Double = 0.25
    static let colorComponentTolerance: Double = 0.012  // ~1/85, matches an HEX-byte diff
}

enum FigmaDiffEngine {
    /// Builds a diff between `viewNode` and `figmaLayer`. The two are
    /// assumed to share a coordinate-system convention — the matcher
    /// uses 1pt == 1px (Figma scale=1) when picking pairs, so we treat
    /// both sides' raw numbers as comparable points here.
    static func diff(viewNode: ViewNode, figmaLayer: FigmaNode) -> FigmaDiff {
        var items: [FigmaDiff.Item] = []
        items.append(contentsOf: sizeItems(viewNode: viewNode, figmaLayer: figmaLayer))
        items.append(fillItem(viewNode: viewNode, figmaLayer: figmaLayer))
        items.append(cornerRadiusItem(viewNode: viewNode, figmaLayer: figmaLayer))
        items.append(contentsOf: typographyItems(viewNode: viewNode, figmaLayer: figmaLayer))
        return FigmaDiff(items: items)
    }

    // MARK: - Size

    private static func sizeItems(
        viewNode: ViewNode,
        figmaLayer: FigmaNode
    ) -> [FigmaDiff.Item] {
        let widthLabel = String(localized: "Width")
        let heightLabel = String(localized: "Height")
        guard let bbox = figmaLayer.absoluteBoundingBox else {
            return [
                FigmaDiff.Item(
                    category: .size, label: widthLabel,
                    figma: nil, device: format(Double(viewNode.windowFrame.width)),
                    status: .unavailable
                ),
                FigmaDiff.Item(
                    category: .size, label: heightLabel,
                    figma: nil, device: format(Double(viewNode.windowFrame.height)),
                    status: .unavailable
                ),
            ]
        }
        let deviceW = Double(viewNode.windowFrame.width)
        let deviceH = Double(viewNode.windowFrame.height)
        return [
            FigmaDiff.Item(
                category: .size, label: widthLabel,
                figma: format(bbox.width), device: format(deviceW),
                status: numericStatus(bbox.width, deviceW, tolerance: FigmaDiff.widthHeightTolerance)
            ),
            FigmaDiff.Item(
                category: .size, label: heightLabel,
                figma: format(bbox.height), device: format(deviceH),
                status: numericStatus(bbox.height, deviceH, tolerance: FigmaDiff.widthHeightTolerance)
            ),
        ]
    }

    // MARK: - Fill

    private static func fillItem(
        viewNode: ViewNode,
        figmaLayer: FigmaNode
    ) -> FigmaDiff.Item {
        let label = String(localized: "Fill")
        let device = viewNode.backgroundColor

        guard let solid = figmaLayer.primarySolidFill, let figmaColor = solid.color else {
            // No solid fill in Figma — surface as unavailable rather than
            // false-positive on a gradient/image fill.
            return FigmaDiff.Item(
                category: .fill, label: label,
                figma: figmaLayer.fills?.isEmpty == false ? figmaFillKindLabel(figmaLayer) : "—",
                device: device.map(rgbaHex) ?? "—",
                status: .unavailable
            )
        }

        // Figma's effective fill alpha = color.a × Paint.opacity. Mirror
        // that on the iOS side with backgroundColor.alpha × view.alpha so
        // a designer who set an alpha via the layer-level Opacity slider
        // doesn't see a false `.differ` against an iOS view that achieves
        // the same look via `view.alpha`.
        let figmaEffectiveAlpha = figmaColor.a * (solid.opacity ?? 1)
        let figmaHex = hexString(
            r: figmaColor.r, g: figmaColor.g, b: figmaColor.b, a: figmaEffectiveAlpha
        )
        guard let device else {
            return FigmaDiff.Item(
                category: .fill, label: label,
                figma: figmaHex, device: "nil",
                status: .differ
            )
        }
        let deviceEffectiveAlpha = device.alpha * viewNode.alpha
        let status: FigmaDiff.Status = colorsMatch(
            r1: device.red, g1: device.green, b1: device.blue, a1: deviceEffectiveAlpha,
            r2: figmaColor.r, g2: figmaColor.g, b2: figmaColor.b, a2: figmaEffectiveAlpha
        ) ? .match : .differ
        return FigmaDiff.Item(
            category: .fill, label: label,
            figma: figmaHex,
            device: hexString(r: device.red, g: device.green, b: device.blue, a: deviceEffectiveAlpha),
            status: status
        )
    }

    private static func figmaFillKindLabel(_ node: FigmaNode) -> String {
        guard let first = node.fills?.first else { return "—" }
        switch first.type {
        case "GRADIENT_LINEAR", "GRADIENT_RADIAL", "GRADIENT_ANGULAR", "GRADIENT_DIAMOND":
            return String(localized: "Gradient")
        case "IMAGE":
            return String(localized: "Image")
        case "SOLID":
            return String(localized: "Solid")
        default:
            return first.type
        }
    }

    // MARK: - Corner radius

    private static func cornerRadiusItem(
        viewNode: ViewNode,
        figmaLayer: FigmaNode
    ) -> FigmaDiff.Item {
        let device = viewNode.cornerRadius
        guard let figma = figmaLayer.effectiveCornerRadius else {
            return FigmaDiff.Item(
                category: .cornerRadius, label: String(localized: "Corner radius"),
                figma: nil, device: format(device),
                status: device > 0 ? .differ : .unavailable
            )
        }
        return FigmaDiff.Item(
            category: .cornerRadius, label: String(localized: "Corner radius"),
            figma: format(figma), device: format(device),
            status: numericStatus(figma, device, tolerance: FigmaDiff.radiusTolerance)
        )
    }

    // MARK: - Typography

    private static func typographyItems(
        viewNode: ViewNode,
        figmaLayer: FigmaNode
    ) -> [FigmaDiff.Item] {
        guard let figmaStyle = figmaLayer.style, let typography = viewNode.typography else {
            // Either side has no typography → no items emitted (don't
            // fill the diff with `—` rows for non-text views).
            return []
        }
        var items: [FigmaDiff.Item] = []

        if let figmaSize = figmaStyle.fontSize {
            items.append(FigmaDiff.Item(
                category: .typography, label: String(localized: "Font size"),
                figma: "\(format(figmaSize))pt",
                device: "\(format(typography.pointSize))pt",
                status: numericStatus(figmaSize, typography.pointSize, tolerance: FigmaDiff.fontSizeTolerance)
            ))
        }

        if let figmaFamily = figmaStyle.fontFamily {
            let deviceFamily = typography.familyName ?? typography.fontName
            items.append(FigmaDiff.Item(
                category: .typography, label: String(localized: "Font family"),
                figma: figmaFamily,
                device: deviceFamily,
                status: caseInsensitiveStatus(figmaFamily, deviceFamily)
            ))
        }

        if let figmaWeight = figmaStyle.fontWeight, let deviceWeight = typography.weight {
            // Figma reports weight on the 100–900 scale; UIKit reports
            // it on a -1.0…+1.0 scale. Normalize the device side to the
            // 100-step CSS scale before comparing so 600 ↔ semibold reads
            // as a match.
            let deviceWeightCSS = cssWeight(forUIFontWeight: deviceWeight)
            items.append(FigmaDiff.Item(
                category: .typography, label: String(localized: "Font weight"),
                figma: format(figmaWeight),
                device: typography.weightName ?? format(deviceWeightCSS),
                // 50-unit slack: SF Semibold reports 590 on macOS while
                // designers always pick 600 in Figma.
                status: numericStatus(figmaWeight, deviceWeightCSS, tolerance: 50)
            ))
        }

        if let figmaLineHeight = computedLineHeightPx(figmaStyle, fontSize: figmaStyle.fontSize),
           let deviceLineHeight = typography.lineHeight {
            items.append(FigmaDiff.Item(
                category: .typography, label: String(localized: "Line height"),
                figma: "\(format(figmaLineHeight))pt",
                device: "\(format(deviceLineHeight))pt",
                status: numericStatus(figmaLineHeight, deviceLineHeight, tolerance: 1)
            ))
        }

        return items
    }

    /// Resolves Figma's three line-height representations into a single
    /// pixel value comparable to `UIFont.lineHeight`.
    private static func computedLineHeightPx(
        _ style: FigmaNode.TextStyle,
        fontSize: Double?
    ) -> Double? {
        if let px = style.lineHeightPx { return px }
        switch style.lineHeightUnit {
        case "FONT_SIZE_%":
            if let pct = style.lineHeightPercent, let size = fontSize {
                return size * pct / 100
            }
        case "INTRINSIC_%":
            // Figma's intrinsic mode means "auto-derived from the font" —
            // we can't reliably reproduce it without rasterising.
            return nil
        default:
            return nil
        }
        return nil
    }

    /// Maps `UIFont.Weight` raw values to CSS-style 100–900 weights.
    /// Linear interpolation between the standard anchor pairs.
    private static func cssWeight(forUIFontWeight value: Double) -> Double {
        let anchors: [(Double, Double)] = [
            (-0.8, 100), // ultraLight
            (-0.6, 200), // thin
            (-0.4, 300), // light
            (0.0, 400),  // regular
            (0.23, 500), // medium
            (0.3, 600),  // semibold
            (0.4, 700),  // bold
            (0.56, 800), // heavy
            (0.62, 900), // black
        ]
        guard let first = anchors.first else { return 400 }
        if value <= first.0 { return first.1 }
        for i in 1..<anchors.count {
            let (prevValue, prevWeight) = anchors[i - 1]
            let (nextValue, nextWeight) = anchors[i]
            if value <= nextValue {
                let t = (value - prevValue) / (nextValue - prevValue)
                return prevWeight + (nextWeight - prevWeight) * t
            }
        }
        return anchors.last?.1 ?? 400
    }

    // MARK: - Helpers

    private static func numericStatus(_ a: Double, _ b: Double, tolerance: Double) -> FigmaDiff.Status {
        abs(a - b) <= tolerance ? .match : .differ
    }

    private static func caseInsensitiveStatus(_ a: String, _ b: String) -> FigmaDiff.Status {
        a.caseInsensitiveCompare(b) == .orderedSame ? .match : .differ
    }

    private static func colorsMatch(
        r1: Double, g1: Double, b1: Double, a1: Double,
        r2: Double, g2: Double, b2: Double, a2: Double
    ) -> Bool {
        let tol = FigmaDiff.colorComponentTolerance
        return abs(r1 - r2) <= tol && abs(g1 - g2) <= tol &&
               abs(b1 - b2) <= tol && abs(a1 - a2) <= tol
    }

    /// Designer-readable `#RRGGBBAA` form. Mirrors `RGBAColor.hexRGBA`
    /// but accepts raw doubles so we can format both sides through one
    /// path.
    private static func hexString(r: Double, g: Double, b: Double, a: Double) -> String {
        func clamp(_ x: Double) -> Int {
            Int((x.isFinite ? max(0, min(1, x)) : 0) * 255 + 0.5)
        }
        return String(
            format: "#%02X%02X%02X%02X",
            clamp(r), clamp(g), clamp(b), clamp(a)
        )
    }

    private static func rgbaHex(_ color: RGBAColor) -> String {
        hexString(r: color.red, g: color.green, b: color.blue, a: color.alpha)
    }

    private static func format(_ value: Double) -> String {
        // Trim trailing zeros: 12.0 → "12", 12.5 → "12.5".
        if value.rounded() == value { return String(format: "%.0f", value) }
        return String(format: "%g", value)
    }
}
