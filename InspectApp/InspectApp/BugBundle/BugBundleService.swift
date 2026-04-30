import Foundation
import AppKit
import UniformTypeIdentifiers
import InspectCore
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "bugbundle")

/// macOS-side glue around the cross-platform `BugBundle` format. Owns the
/// NSSavePanel / NSOpenPanel presentation, default file naming, and the
/// optional in-panel notes editor; the on-wire shape itself lives in
/// `InspectCore` so a future iOS-side capture-to-file pipeline (or a
/// command-line dumper) can re-use it.
@MainActor
enum BugBundleService {
    /// On-disk type for a `.swiftinspector` document. Bound dynamically
    /// from the filename extension because the SPM-built app ships
    /// without an `Info.plist` in which we could register an exported
    /// UTI; this is still enough to drive the panel filters and would
    /// silently start cooperating with a registered UTI later if/when
    /// the build adds one.
    static var contentType: UTType {
        UTType(filenameExtension: BugBundle.fileExtension, conformingTo: .json)
            ?? .json
    }

    /// Reason a `read(from:)` call refused a URL. Carried up so the
    /// caller can produce a user-meaningful alert instead of the generic
    /// `DecodingError` text.
    enum LoadError: LocalizedError {
        case unsupportedExtension(URL)
        case decoding(Error)
        case io(Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedExtension(let url):
                return String(localized: "Not a swift-inspector bundle: \(url.lastPathComponent)")
            case .decoding(let underlying):
                return String(localized: "Couldn't read bundle: \(underlying.localizedDescription)")
            case .io(let underlying):
                return String(localized: "Couldn't open file: \(underlying.localizedDescription)")
            }
        }
    }

    // MARK: - Save

    /// Presents an `NSSavePanel` (with an inline notes field) and writes
    /// `bundle` to the chosen URL. Returns the destination URL on
    /// success, `nil` if the user cancelled. The notes typed into the
    /// accessory view replace `bundle.manifest.notes` if non-empty —
    /// callers can pass an already-populated `notes` to seed the field.
    static func presentSavePanel(for bundle: BugBundle, defaultName: String) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sanitizedFileName(defaultName)
        panel.title = String(localized: "Export Bug Bundle")
        panel.prompt = String(localized: "Export")

        let accessory = NotesAccessoryView(initialText: bundle.manifest.notes ?? "")
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let typedNotes = accessory.notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = mergingNotes(into: bundle, notes: typedNotes.isEmpty ? nil : typedNotes)
        try write(merged, to: url)
        return url
    }

    /// Direct-to-disk writer without UI. Exposed so tests can exercise
    /// the round-trip without mocking a panel; production paths go
    /// through `presentSavePanel` instead.
    static func write(_ bundle: BugBundle, to url: URL) throws {
        let data = try bundle.encoded()
        try data.write(to: url, options: [.atomic])
        logger.info("Wrote bundle: \(url.path, privacy: .public) (\(data.count) bytes)")
    }

    // MARK: - Load

    /// Presents an `NSOpenPanel` and returns the loaded bundle along
    /// with the URL the user chose. Returns `nil` if the user cancelled.
    /// Failures are wrapped in `LoadError` so the caller can route them
    /// to a user-readable alert.
    static func presentOpenPanel() throws -> (bundle: BugBundle, url: URL)? {
        let panel = NSOpenPanel()
        // `.json` is included as a fallback so users who renamed the
        // extension while editing notes can still open the file. The
        // primary `contentType` keeps the picker filtered to bundles
        // by default.
        panel.allowedContentTypes = [contentType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = String(localized: "Open Bug Bundle")
        panel.prompt = String(localized: "Open")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let bundle = try read(from: url)
        return (bundle, url)
    }

    static func read(from url: URL) throws -> BugBundle {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.io(error)
        }
        do {
            let bundle = try BugBundle.decoded(from: data)
            logger.info("Read bundle: \(url.path, privacy: .public) (\(data.count) bytes)")
            return bundle
        } catch let typed as BugBundle.DecodeError {
            // Forward as-is so its `LocalizedError` description (e.g.
            // "Upgrade AppInspector to open it.") reaches the alert
            // unchanged instead of being swallowed by `LoadError.decoding`,
            // whose underlying `DecodingError` has no `errorDescription`.
            throw typed
        } catch {
            throw LoadError.decoding(error)
        }
    }

    // MARK: - File naming

    /// Builds a default file name like `iPhone-15-Pro-2026-04-30-1530`
    /// (no extension — the panel adds it). Strips path-unfriendly
    /// characters from `deviceName` and falls back to "Bug Bundle"
    /// when no device is available.
    static func defaultFileName(deviceName: String?, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let stamp = formatter.string(from: date)
        let base: String = {
            guard let deviceName,
                  !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return "Bug Bundle" }
            return deviceName
        }()
        return "\(sanitizedFileName(base))-\(stamp)"
    }

    private static func sanitizedFileName(_ name: String) -> String {
        // `/` and `:` (Finder silently re-renders ":" to "/") plus NUL
        // are the path-illegal characters on macOS. Replace with hyphen
        // so the suggested name survives copy-paste between tools.
        let unsafe: Set<Character> = ["/", ":", "\0"]
        return String(name.map { unsafe.contains($0) ? "-" : $0 })
    }

    // MARK: - Helpers

    private static func mergingNotes(into bundle: BugBundle, notes: String?) -> BugBundle {
        guard let notes else { return bundle }
        let merged = BugBundle.Manifest(
            schemaVersion: bundle.manifest.schemaVersion,
            createdAt: bundle.manifest.createdAt,
            exporterAppVersion: bundle.manifest.exporterAppVersion,
            notes: notes,
            deviceName: bundle.manifest.deviceName,
            systemName: bundle.manifest.systemName,
            systemVersion: bundle.manifest.systemVersion,
            protocolVersion: bundle.manifest.protocolVersion
        )
        return BugBundle(manifest: merged, roots: bundle.roots)
    }
}

// MARK: - NSSavePanel accessory

/// Inline "Notes" editor shown above the Save panel's confirm button.
/// Uses an `NSTextView` (not `NSTextField`) so the input area scrolls
/// for multi-line repro steps; the panel's modal lifecycle keeps the
/// view alive long enough for `notesText` to be sampled after
/// `runModal()` returns.
private final class NotesAccessoryView: NSView {
    private let textView: NSTextView

    var notesText: String {
        textView.string
    }

    init(initialText: String) {
        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tv = NSTextView()
        tv.isEditable = true
        tv.isRichText = false
        tv.string = initialText
        tv.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        // Auto-grow the document height while the panel resizes.
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        scrollView.documentView = tv

        let label = NSTextField(labelWithString: String(localized: "Notes (optional, e.g. repro steps)"))
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        self.textView = tv
        // 160pt accessory height ≈ 6 lines of small system text after
        // label / padding chrome. NSSavePanel itself isn't user-resizable,
        // so erring tall is the only way to make multi-line repro-step
        // entries reasonable to type without horizontal compression.
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 160))
        addSubview(label)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
