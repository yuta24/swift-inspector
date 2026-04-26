import Foundation
import AppKit
import Combine
import InspectCore

/// View model for the Figma compare section in the inspector. Lives
/// alongside `InspectAppModel` (not inside it) because Figma state is
/// orthogonal to the inspector connection — designers may want to keep
/// their last-fetched Figma frame visible while reconnecting to a new
/// device, and Figma fetch failures shouldn't show up next to TCP-level
/// connection errors.
@MainActor
final class FigmaComparisonModel: ObservableObject {
    /// How the device screenshot and the Figma frame are arranged in the
    /// compare section. Modes other than `.deviceOnly` are no-ops until the
    /// user has fetched a Figma image at least once.
    enum DisplayMode: String, CaseIterable, Identifiable {
        case deviceOnly
        case figmaOnly
        case sideBySide
        case overlay
        case difference
        case heatmap

        var id: String { rawValue }

        var label: String {
            switch self {
            case .deviceOnly: return String(localized: "Device")
            case .figmaOnly: return String(localized: "Figma")
            case .sideBySide: return String(localized: "Side by Side")
            case .overlay: return String(localized: "Overlay")
            case .difference: return String(localized: "Difference")
            case .heatmap: return String(localized: "Heatmap")
            }
        }
    }

    /// Width-mismatch warning surfaced when the device window and the
    /// Figma frame disagree on canvas width. Designers see this most often
    /// when their Figma file is sized to an older iPhone (375 / 390) but
    /// the device they're testing on is wider — the overlay would lie
    /// without this warning.
    struct SizeWarning: Equatable {
        let devicePoints: Double
        let figmaPoints: Double
    }

    // MARK: - Published state

    /// Raw URL the user typed into the compare bar. We intentionally keep
    /// this as a mutable string (not a parsed `FrameReference`) so the
    /// text field never re-renders mid-typing.
    @Published var frameURL: String
    @Published var displayMode: DisplayMode = .deviceOnly
    @Published var overlayOpacity: Double = 0.5
    @Published var maskStatusBar: Bool = false
    @Published private(set) var image: NSImage?
    @Published private(set) var imagePixelSize: CGSize?
    /// Scale Figma rendered the image at. Combined with `imagePixelSize`
    /// it produces the design's logical points width — used by the size-
    /// mismatch warning and the heatmap coordinate mapping.
    @Published private(set) var imageScale: Int = FigmaImageService.defaultImageScale
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastFetchedFromCache: Bool = false
    @Published private(set) var sizeWarning: SizeWarning?
    /// All ViewNode → Figma layer matches in the currently-loaded
    /// hierarchy. Recomputed when either the Figma frame or the inspector's
    /// roots change. Empty until a frame has been fetched.
    @Published private(set) var matches: [UUID: FigmaLayerMatcher.Match] = [:]
    /// Cached diffs keyed by ViewNode ident. Populated alongside
    /// `matches` so the inspector's diff section and the heatmap don't
    /// re-run `FigmaDiffEngine.diff` per render.
    @Published private(set) var diffs: [UUID: FigmaDiff] = [:]
    /// All matched ViewNode IDs whose `FigmaDiff` flags at least one
    /// differing attribute. Drives the heatmap overlay.
    @Published private(set) var differingNodeIDs: Set<UUID> = []

    // MARK: - Dependencies

    private let service: FigmaImageService
    private var fetchTask: Task<Void, Never>?
    private var layerTree: FigmaNode?
    private var lastRoots: [ViewNode] = []

    init(service: FigmaImageService = FigmaImageService()) {
        self.service = service
        self.frameURL = UserDefaults.standard.string(forKey: UserPreferences.Keys.figmaLastFrameURL) ?? ""
    }

    // MARK: - Actions

    /// Triggers a fresh fetch using the current `frameURL` and the saved
    /// PAT. Cancellable: typing a new URL while a fetch is in flight rolls
    /// the previous one back. The PAT is read from Keychain on every call
    /// so a Settings change applies immediately without explicit wiring.
    func fetch() {
        fetchTask?.cancel()
        errorMessage = nil
        guard let ref = FigmaImageService.parse(frameURL) else {
            errorMessage = FigmaImageService.ServiceError.invalidURL.localizedDescription
            return
        }
        guard let token = FigmaTokenStore.load(), !token.isEmpty else {
            errorMessage = FigmaImageService.ServiceError.missingToken.localizedDescription
            return
        }
        // Persist URL on a successful parse so the compare bar pre-fills
        // with the same value next launch.
        UserDefaults.standard.set(frameURL, forKey: UserPreferences.Keys.figmaLastFrameURL)

        isLoading = true
        let service = self.service
        fetchTask = Task { @MainActor [weak self] in
            // Inheriting MainActor here keeps `defer` on the same isolation
            // domain as the @Published writes, so `isLoading = false` lands
            // synchronously when the task ends — including when the user
            // cancels mid-flight by retyping the URL or hitting clear.
            defer { self?.isLoading = false }
            do {
                async let imageFetch = service.fetchImage(ref: ref, token: token)
                async let nodesFetch = service.fetchNodes(ref: ref, token: token)
                let (result, layerTree) = try await (imageFetch, nodesFetch)
                guard !Task.isCancelled, let self else { return }
                let nsImage = NSImage(data: result.data)
                self.image = nsImage
                self.imagePixelSize = nsImage.flatMap { Self.pixelSize(of: $0) }
                self.imageScale = result.scale
                self.lastFetchedFromCache = result.fromCache
                self.layerTree = layerTree
                self.recomputeMatches()
                if self.displayMode == .deviceOnly {
                    self.displayMode = .sideBySide
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Clears the in-memory image and the on-disk cache. The URL field is
    /// preserved on purpose — a designer who hits "Clear" and re-fetches
    /// usually wants the same frame freshly rendered.
    func clear() {
        fetchTask?.cancel()
        image = nil
        imagePixelSize = nil
        sizeWarning = nil
        lastFetchedFromCache = false
        errorMessage = nil
        layerTree = nil
        matches = [:]
        diffs = [:]
        differingNodeIDs = []
        service.clearCache()
    }

    /// Tells the model that the inspector's hierarchy has been reloaded
    /// (fresh capture or live-mode tick). Recomputes the match table so
    /// the diff section and heatmap stay in sync with the new ViewNodes.
    func updateRoots(_ roots: [ViewNode]) {
        lastRoots = roots
        recomputeMatches()
    }

    /// Returns the cached match for a ViewNode, or computes one on the
    /// fly when no whole-tree pass has been done yet (e.g. user pasted a
    /// URL but the hierarchy is empty).
    func match(for viewNode: ViewNode) -> FigmaLayerMatcher.Match? {
        if let cached = matches[viewNode.ident] { return cached }
        guard let layerTree else { return nil }
        return FigmaLayerMatcher(frame: layerTree).match(viewNode: viewNode)
    }

    /// Diff between a ViewNode and its matched Figma layer. Reads from
    /// the cache populated by `recomputeMatches`; falls back to live
    /// computation for ViewNodes that were added after the last
    /// `updateRoots` (single-shot inspections).
    func diff(for viewNode: ViewNode) -> FigmaDiff? {
        if let cached = diffs[viewNode.ident] { return cached }
        guard let match = match(for: viewNode) else { return nil }
        return FigmaDiffEngine.diff(viewNode: viewNode, figmaLayer: match.layer)
    }

    /// Single-pass match + diff over the current roots. Both maps and
    /// the differing-set are filled together so the heatmap overlay,
    /// the diff section and any future readers see one consistent
    /// snapshot.
    private func recomputeMatches() {
        guard let layerTree, !lastRoots.isEmpty else {
            matches = [:]
            diffs = [:]
            differingNodeIDs = []
            return
        }
        let matcher = FigmaLayerMatcher(frame: layerTree)
        var matchTable: [UUID: FigmaLayerMatcher.Match] = [:]
        var diffTable: [UUID: FigmaDiff] = [:]
        var differing: Set<UUID> = []
        for root in lastRoots {
            walkAndMatch(
                node: root,
                using: matcher,
                matches: &matchTable,
                diffs: &diffTable,
                differing: &differing
            )
        }
        matches = matchTable
        diffs = diffTable
        differingNodeIDs = differing
    }

    private func walkAndMatch(
        node: ViewNode,
        using matcher: FigmaLayerMatcher,
        matches: inout [UUID: FigmaLayerMatcher.Match],
        diffs: inout [UUID: FigmaDiff],
        differing: inout Set<UUID>
    ) {
        if let match = matcher.match(viewNode: node) {
            matches[node.ident] = match
            let diff = FigmaDiffEngine.diff(viewNode: node, figmaLayer: match.layer)
            diffs[node.ident] = diff
            if diff.hasDifference {
                differing.insert(node.ident)
            }
        }
        for child in node.children {
            walkAndMatch(
                node: child,
                using: matcher,
                matches: &matches,
                diffs: &diffs,
                differing: &differing
            )
        }
    }

    /// Recomputes `sizeWarning` whenever the inspector's selected device
    /// node changes. Figma renders at `imageScale`, so dividing the pixel
    /// width by it produces the design's logical points width —
    /// comparable to the device window width directly.
    func updateSizeWarning(deviceWindowWidth: Double?) {
        guard let pixelWidth = imagePixelSize?.width, pixelWidth > 0,
              let deviceWidth = deviceWindowWidth, deviceWidth > 0,
              imageScale > 0 else {
            sizeWarning = nil
            return
        }
        let figmaPoints = Double(pixelWidth) / Double(imageScale)
        // 1pt tolerance keeps subpixel rounding from triggering a warning
        // on otherwise-aligned designs.
        if abs(figmaPoints - deviceWidth) >= 1.0 {
            sizeWarning = SizeWarning(devicePoints: deviceWidth, figmaPoints: figmaPoints)
        } else {
            sizeWarning = nil
        }
    }

    // MARK: - Helpers

    /// Pulls the underlying CGImage's pixel dimensions out of an `NSImage`.
    /// `NSImage.size` reports points, but we need pixels here so the
    /// scale=2 PNG returned by Figma is interpreted correctly when comparing
    /// to the device window's points width.
    private static func pixelSize(of image: NSImage) -> CGSize? {
        guard let rep = image.representations.first else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
