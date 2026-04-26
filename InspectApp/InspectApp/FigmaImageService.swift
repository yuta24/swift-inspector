import Foundation

/// Figma REST API client for fetching a single rendered frame image.
///
/// The endpoint is two-step: `GET /v1/images/:fileKey?ids=:nodeId&format=png`
/// returns a short-lived CloudFront URL, then a follow-up GET against that
/// URL streams the PNG. Designers can re-render the same frame any number
/// of times — the CloudFront URL is good for ~30 days but each call is
/// metered against the user's per-minute rate limit, so we keep a tiny
/// on-disk cache (`~/Library/Caches/swift-inspector/figma/`) keyed on
/// `(fileKey, nodeId)` to soak up "open the same screen ten times" loops.
///
/// PAT and `URLSession` are injected so tests can stub them out via
/// `URLProtocol`. Production callers use `FigmaImageService()` and
/// `FigmaTokenStore.load()`.
struct FigmaImageService {
    enum ServiceError: Error, LocalizedError {
        case invalidURL
        case missingToken
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case nodeNotFound
        case network(Error)
        case unexpectedStatus(Int)
        case decoding

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return String(localized: "Check the Figma URL. Paste a frame share link.")
            case .missingToken:
                return String(localized: "Set a Figma Personal Access Token in Preferences first.")
            case .unauthorized:
                return String(localized: "Figma rejected the token. Check that it's still valid.")
            case .rateLimited:
                return String(localized: "Hit the Figma rate limit. Wait a moment and try again.")
            case .nodeNotFound:
                return String(localized: "Couldn't find that frame in Figma.")
            case .network(let error):
                return error.localizedDescription
            case .unexpectedStatus(let code):
                return String(localized: "Figma returned an error (HTTP \(code))")
            case .decoding:
                return String(localized: "Couldn't decode the Figma response.")
            }
        }
    }

    /// Reference to a single Figma frame on a given file. URL-shaped input
    /// is normalized into this internal representation so the rest of the
    /// pipeline doesn't need to think about hyphen/colon node-id quirks.
    struct FrameReference: Equatable {
        let fileKey: String
        /// Already in REST form (`A:B`), not URL form (`A-B`).
        let nodeId: String
    }

    /// Successful fetch result. `data` is raw PNG bytes ready to feed to
    /// `NSImage(data:)`. `pixelSize` is filled in by the live client when
    /// it can be cheaply derived; the in-memory cache treats it as opaque.
    struct ImageResult {
        let data: Data
        /// Whether this came from disk cache vs a live API hit. Surfaced so
        /// the UI can hint "cached" without a separate isStale tracker.
        let fromCache: Bool
        /// Scale at which the image was rendered. Carried alongside the
        /// bytes so downstream code (size-mismatch warning, heatmap
        /// coords) doesn't re-hardcode the value the service used.
        let scale: Int
    }

    /// Default scale we ask Figma to render at. iOS device screenshots
    /// also come back at 2x (see `ScreenshotCapture.swift`), so picking
    /// the same value keeps the px-vs-px comparison straight.
    static let defaultImageScale: Int = 2

    private let session: URLSession
    private let cacheDirectory: URL

    init(session: URLSession = .shared, cacheDirectory: URL? = nil) {
        self.session = session
        self.cacheDirectory = cacheDirectory ?? FigmaImageService.defaultCacheDirectory()
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("swift-inspector/figma", isDirectory: true)
    }

    // MARK: - URL parsing

    /// Parses a Figma share URL into a `(fileKey, nodeId)` pair. Returns
    /// `nil` for anything that isn't recognisably a Figma URL with a
    /// `node-id` query parameter.
    ///
    /// Accepts both `figma.com/file/...` and `figma.com/design/...` (Figma
    /// auto-redirects the older /file/ path, but designers still copy URLs
    /// from both). The node-id in URLs is hyphen-separated (`5-3`); the
    /// REST API expects colon-separated (`5:3`), so we normalize here.
    static func parse(_ raw: String) -> FrameReference? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host,
              host.hasSuffix("figma.com") else {
            return nil
        }
        // Path: /file/<KEY>/<slug...> or /design/<KEY>/<slug...>
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2,
              parts[0] == "file" || parts[0] == "design" else {
            return nil
        }
        let fileKey = parts[1]
        guard !fileKey.isEmpty else { return nil }

        guard let queryItems = components.queryItems,
              let nodeIdRaw = queryItems.first(where: { $0.name == "node-id" })?.value,
              !nodeIdRaw.isEmpty else {
            return nil
        }
        // URL forms: "5-3" or already-encoded "5%3A3" (URLComponents
        // decodes the latter back to "5:3"). Normalise hyphen form to
        // colon form, but skip when the value already contains a colon
        // — Figma can issue compound IDs like `I5:3;4:8` for component
        // instances that include hyphens we mustn't touch.
        let normalized = nodeIdRaw.contains(":")
            ? nodeIdRaw
            : nodeIdRaw.replacingOccurrences(of: "-", with: ":")
        return FrameReference(fileKey: fileKey, nodeId: normalized)
    }

    // MARK: - Fetch

    /// Two-step fetch with a small on-disk cache. The token is taken as a
    /// parameter rather than read from `FigmaTokenStore` so callers can run
    /// in test contexts without touching Keychain.
    func fetchImage(
        ref: FrameReference,
        token: String,
        scale: Int = FigmaImageService.defaultImageScale,
        useCache: Bool = true
    ) async throws -> ImageResult {
        guard !token.isEmpty else { throw ServiceError.missingToken }

        if useCache, let cached = try? readCache(for: ref, scale: scale) {
            return ImageResult(data: cached, fromCache: true, scale: scale)
        }

        // Step 1: ask Figma to render and give us a CloudFront URL.
        let cloudfrontURL = try await fetchRenderURL(ref: ref, token: token, scale: scale)

        // Step 2: download the PNG from CloudFront. No auth header — the
        // signed URL is its own credential.
        let data: Data
        do {
            let (downloaded, response) = try await session.data(from: cloudfrontURL)
            guard let http = response as? HTTPURLResponse else {
                throw ServiceError.decoding
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ServiceError.unexpectedStatus(http.statusCode)
            }
            data = downloaded
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.network(error)
        }

        try? writeCache(data, for: ref, scale: scale)
        return ImageResult(data: data, fromCache: false, scale: scale)
    }

    /// Step 1 of the fetch flow, exposed separately so tests can verify the
    /// request shape without spinning up a CloudFront stub.
    private func fetchRenderURL(
        ref: FrameReference,
        token: String,
        scale: Int
    ) async throws -> URL {
        var components = URLComponents(string: "https://api.figma.com/v1/images/\(ref.fileKey)")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: ref.nodeId),
            URLQueryItem(name: "format", value: "png"),
            URLQueryItem(name: "scale", value: String(scale)),
        ]
        guard let url = components.url else { throw ServiceError.invalidURL }
        let data = try await sendAuthenticated(url: url, token: token)

        struct Envelope: Decodable {
            let images: [String: String?]
            let err: String?
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ServiceError.decoding
        }
        if let err = envelope.err, !err.isEmpty {
            // Figma returns 200 with an `err` field for some failures (e.g.
            // node id present but renders to nothing) — surface as not found.
            throw ServiceError.nodeNotFound
        }
        guard let urlString = envelope.images[ref.nodeId] ?? nil,
              let url = URL(string: urlString) else {
            throw ServiceError.nodeNotFound
        }
        return url
    }

    /// Shared GET path for authenticated Figma REST calls. Wraps URLSession
    /// errors as `ServiceError.network`, asserts that we got an HTTP
    /// response, and maps status codes onto the meaningful error cases.
    /// 200..<300 returns the body bytes; everything else throws.
    private func sendAuthenticated(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.decoding
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw ServiceError.unauthorized
        case 404:
            throw ServiceError.nodeNotFound
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ServiceError.rateLimited(retryAfter: retryAfter)
        default:
            throw ServiceError.unexpectedStatus(http.statusCode)
        }
    }

    // MARK: - Disk cache

    private func cacheURL(for ref: FrameReference, scale: Int) -> URL {
        // Hash the node id to keep filenames safe (`:` is fine on APFS but
        // we don't want to think about edge cases). Including the scale
        // means a future "fetch at 1x" toggle won't collide with the 2x
        // cache.
        let safeNodeId = ref.nodeId.replacingOccurrences(of: ":", with: "_")
        let filename = "\(ref.fileKey)-\(safeNodeId)@\(scale)x.png"
        return cacheDirectory.appendingPathComponent(filename)
    }

    private func readCache(for ref: FrameReference, scale: Int) throws -> Data? {
        let url = cacheURL(for: ref, scale: scale)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Match the 30-day promise the type's doc comment makes. Stale
        // entries are dropped lazily here so a reopen-after-update flow
        // doesn't keep handing back a pre-edit PNG. The user's "Clear"
        // button still exists for the impatient case.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let modified = attrs?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 30 * 24 * 3600 {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return try Data(contentsOf: url)
    }

    private func writeCache(_ data: Data, for ref: FrameReference, scale: Int) throws {
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: cacheURL(for: ref, scale: scale), options: .atomic)
    }

    /// Wipes every entry under the cache directory. Surfaced via Preferences
    /// so designers can force a refetch when the Figma file has been edited
    /// since the last grab — the cache has no ETag/Last-Modified handshake
    /// because the CloudFront URL changes per-render and isn't stable to
    /// validate against.
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: - Node tree fetch

    /// Fetches the node subtree rooted at `ref.nodeId` so the diff layer
    /// can match Figma layers against iOS ViewNodes by name and structure.
    /// One-shot REST call — no on-disk cache because the JSON is small
    /// (~hundreds of KB even for big screens) and the user typically wants
    /// fresh data when they re-fetch the image anyway.
    func fetchNodes(
        ref: FrameReference,
        token: String
    ) async throws -> FigmaNode {
        guard !token.isEmpty else { throw ServiceError.missingToken }

        var components = URLComponents(string: "https://api.figma.com/v1/files/\(ref.fileKey)/nodes")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: ref.nodeId),
            // depth omitted — we want the full subtree under the frame so
            // the matcher has every leaf available. Frame trees rarely go
            // beyond a few hundred nodes, so the size penalty is small.
        ]
        guard let url = components.url else { throw ServiceError.invalidURL }
        let data = try await sendAuthenticated(url: url, token: token)

        struct Envelope: Decodable {
            struct NodeBox: Decodable { let document: FigmaNode }
            let nodes: [String: NodeBox]
            let err: String?
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ServiceError.decoding
        }
        if let err = envelope.err, !err.isEmpty {
            throw ServiceError.nodeNotFound
        }
        guard let box = envelope.nodes[ref.nodeId] else {
            throw ServiceError.nodeNotFound
        }
        return box.document
    }
}
