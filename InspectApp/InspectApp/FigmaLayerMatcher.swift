import Foundation
import CoreGraphics
import InspectCore

/// Maps each `ViewNode` in a captured iOS hierarchy onto its most likely
/// counterpart in a Figma frame so the diff layer and the heatmap can
/// look up "what was this layer supposed to be" by `ViewNode.id`.
///
/// Strategy (in priority order):
///   1. **Exact name match** — `accessibilityIdentifier` == Figma layer
///      `name`. The intentional path: design system teams that share a
///      naming convention between Figma and code.
///   2. **Text content match** — `UILabel.text` (carried in
///      `ViewNode.properties["text"]`) == Figma TEXT layer `characters`.
///      Catches the common case where a developer didn't bother to set
///      an a11y identifier on a one-off label.
///   3. **Bounding box proximity** — closest layer in the Figma frame's
///      relative coord space, weighted by size + position similarity.
///      Last resort; produces matches even when names disagree, but the
///      diff layer will discard low-confidence matches.
///
/// Matches are pre-computed eagerly so the heatmap can render without
/// per-frame walks. The match table is keyed by `ViewNode.ident`, which
/// regenerates per capture — recompute whenever a fresh tree comes in.
struct FigmaLayerMatcher {
    /// Per-ViewNode result. `confidence` is in `[0, 1]`; UI surfaces
    /// only `medium` and `high` so the user isn't shown obviously-wrong
    /// pairings just because every ViewNode has *some* nearest neighbour.
    struct Match: Equatable {
        let layer: FigmaNode
        let strategy: Strategy
        let confidence: Confidence

        enum Strategy: String, Equatable {
            case identifierName
            case textContent
            case boundingBox
        }

        enum Confidence: String, Equatable, Comparable {
            case low
            case medium
            case high

            private var rank: Int {
                switch self {
                case .low: return 0
                case .medium: return 1
                case .high: return 2
                }
            }

            static func < (lhs: Confidence, rhs: Confidence) -> Bool {
                lhs.rank < rhs.rank
            }
        }
    }

    private let frame: FigmaNode
    private let frameOrigin: CGPoint
    /// `name` → first matching FigmaNode in pre-order. Pre-built once so
    /// per-ViewNode lookups are O(1).
    private let byName: [String: FigmaNode]
    /// `characters` (TEXT nodes only) → FigmaNode. TEXT layers without
    /// a unique name are very common, so this index is the only realistic
    /// way to find them.
    private let byText: [String: FigmaNode]
    /// All non-frame layers, used for bbox fallback. The frame itself is
    /// excluded so the fallback never collapses every ViewNode onto the
    /// root frame.
    private let candidates: [FigmaNode]

    init(frame: FigmaNode) {
        self.frame = frame
        self.frameOrigin = CGPoint(
            x: frame.absoluteBoundingBox?.x ?? 0,
            y: frame.absoluteBoundingBox?.y ?? 0
        )
        let flat = frame.flattened().filter { $0.id != frame.id }
        var names: [String: FigmaNode] = [:]
        var texts: [String: FigmaNode] = [:]
        for node in flat {
            // `Dictionary(uniqueKeysWithValues:)` would crash on dupes; skip
            // duplicates so the first occurrence wins. Designers do reuse
            // names like "Title", and we'd rather give a stable answer than
            // throw.
            if !node.name.isEmpty, names[node.name] == nil {
                names[node.name] = node
            }
            if let text = node.characters, !text.isEmpty, texts[text] == nil {
                texts[text] = node
            }
        }
        self.byName = names
        self.byText = texts
        self.candidates = flat
    }

    /// Computes a `Match` for every ViewNode reachable from `roots`.
    /// Returns a dictionary keyed by `ViewNode.ident`, including only
    /// ViewNodes that produced a match — absent keys mean "no Figma
    /// counterpart found".
    func matchAll(roots: [ViewNode]) -> [UUID: Match] {
        var output: [UUID: Match] = [:]
        for root in roots {
            walk(node: root, into: &output)
        }
        return output
    }

    /// Single-shot lookup for cases where you only need the selected
    /// ViewNode's match. Builds against the same indexes as `matchAll`,
    /// so results agree.
    func match(viewNode: ViewNode) -> Match? {
        if let id = viewNode.accessibilityIdentifier,
           !id.isEmpty,
           let layer = byName[id] {
            return Match(layer: layer, strategy: .identifierName, confidence: .high)
        }
        if let text = viewNode.properties["text"],
           !text.isEmpty,
           let layer = byText[text] {
            return Match(layer: layer, strategy: .textContent, confidence: .high)
        }
        return bboxMatch(for: viewNode)
    }

    private func walk(node: ViewNode, into output: inout [UUID: Match]) {
        if let match = match(viewNode: node) {
            output[node.ident] = match
        }
        for child in node.children {
            walk(node: child, into: &output)
        }
    }

    /// Bounding-box fallback. Compares each candidate Figma layer's
    /// frame-relative rect against the ViewNode's window-frame rect and
    /// picks the closest. Confidence drops with the IoU shortfall so the
    /// UI can hide unreliable matches.
    private func bboxMatch(for viewNode: ViewNode) -> Match? {
        let window = viewNode.windowFrame
        guard window.width > 1, window.height > 1 else { return nil }

        var best: (layer: FigmaNode, score: Double)?
        for candidate in candidates {
            guard let bbox = candidate.absoluteBoundingBox else { continue }
            let relative = CGRect(
                x: bbox.x - frameOrigin.x,
                y: bbox.y - frameOrigin.y,
                width: bbox.width,
                height: bbox.height
            )
            // IoU on the two rects. Use raw points on both sides — the
            // caller is responsible for ensuring scale parity (Figma
            // frame at scale=1 == device window in points).
            let score = Self.intersectionOverUnion(window, relative)
            if score > 0, score > (best?.score ?? 0) {
                best = (candidate, score)
            }
        }
        guard let best, best.score >= 0.4 else { return nil }
        let confidence: Match.Confidence = {
            if best.score >= 0.8 { return .high }
            if best.score >= 0.6 { return .medium }
            return .low
        }()
        return Match(layer: best.layer, strategy: .boundingBox, confidence: confidence)
    }

    /// Standard IoU. Returns 0 for non-overlapping rects so the caller
    /// can short-circuit.
    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let interArea = Double(intersection.width * intersection.height)
        let unionArea = Double(a.width * a.height) + Double(b.width * b.height) - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }
}
