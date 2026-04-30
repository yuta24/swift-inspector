#if (DEBUG || SWIFT_INSPECTOR_ENABLED) && canImport(UIKit)
import UIKit
import os.log

private let logger = Logger(subsystem: "swift-inspector", category: "connection-info")

/// On-device "Connect by IP" cheat sheet. Designers / QA call this from
/// a debug menu when the macOS client can't see the device through
/// Bonjour discovery (corp Wi-Fi client isolation, guest networks, etc.)
/// — they read the displayed `host:port` off the screen and type it
/// into the AppInspector's "Connect by IP" sheet.
///
/// Shown in a dedicated `UIWindow` overlay (alert level + 1) for the
/// same reason `PairingPrompt` is — the host app shouldn't need to
/// expose any view-controller hook for what is fundamentally a debug
/// affordance. Tap-anywhere-to-dismiss; no host action required.
@MainActor
enum ConnectionInfoOverlay {
    private static var window: UIWindow?

    /// Presents the overlay. Idempotent: calling it again while the
    /// overlay is already up replaces the displayed values and bumps
    /// the dismiss timer, so a user who toggled the menu twice doesn't
    /// see a stack of overlays.
    static func show(host: String, port: UInt16, instructions: String? = nil) {
        guard let scene = activeScene() else {
            logger.warning("ConnectionInfoOverlay requested without an active UIWindowScene; skipping")
            return
        }

        if let existing = window {
            existing.isHidden = true
            window = nil
        }

        let new = UIWindow(windowScene: scene)
        new.windowLevel = .alert + 1
        new.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        let host = ConnectionInfoHostController(
            address: host,
            port: port,
            instructions: instructions ?? defaultInstructions
        )
        host.onDismiss = { hide() }
        new.rootViewController = host
        new.makeKeyAndVisible()
        window = new
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let foreground = scenes.first(where: { $0.activationState == .foregroundActive }) {
            return foreground
        }
        return scenes.first
    }

    private static let defaultInstructions = "AppInspector → Sidebar → Connect by IP… にホスト/ポートを入力してください。"
}

private final class ConnectionInfoHostController: UIViewController {
    private let address: String
    private let port: UInt16
    private let instructions: String

    var onDismiss: (() -> Void)?

    init(address: String, port: UInt16, instructions: String) {
        self.address = address
        self.port = port
        self.instructions = instructions
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 16
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.25
        card.layer.shadowRadius = 24
        card.layer.shadowOffset = CGSize(width: 0, height: 8)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "swift-inspector に接続"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .label

        let addressLabel = UILabel()
        addressLabel.translatesAutoresizingMaskIntoConstraints = false
        addressLabel.text = "\(address):\(port)"
        addressLabel.font = .monospacedSystemFont(ofSize: 28, weight: .semibold)
        addressLabel.textColor = .label
        addressLabel.adjustsFontSizeToFitWidth = true
        addressLabel.minimumScaleFactor = 0.6

        let instructionsLabel = UILabel()
        instructionsLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionsLabel.text = instructions
        instructionsLabel.font = .preferredFont(forTextStyle: .footnote)
        instructionsLabel.textColor = .secondaryLabel
        instructionsLabel.numberOfLines = 0

        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("閉じる", for: .normal)
        closeButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        closeButton.addAction(UIAction { [weak self] _ in
            self?.onDismiss?()
        }, for: .touchUpInside)

        view.addSubview(card)
        card.addSubview(title)
        card.addSubview(addressLabel)
        card.addSubview(instructionsLabel)
        card.addSubview(closeButton)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 480),

            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

            addressLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            addressLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            addressLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

            instructionsLabel.topAnchor.constraint(equalTo: addressLabel.bottomAnchor, constant: 12),
            instructionsLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            instructionsLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

            closeButton.topAnchor.constraint(equalTo: instructionsLabel.bottomAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            closeButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        // Tap outside the card dismisses — designer-friendly and matches
        // the standard system "tap dimmed background to close" gesture.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        // Long-press on the address copies it. No visible affordance —
        // the QA usage pattern is "read it aloud, type into Mac", but
        // the copy fallback covers the over-the-shoulder remote case.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleAddressLongPress(_:)))
        addressLabel.isUserInteractionEnabled = true
        addressLabel.addGestureRecognizer(longPress)
    }

    @objc private func handleBackgroundTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: view)
        // Only dismiss when the tap lands outside the card, otherwise
        // the user accidentally closes while trying to long-press the
        // address.
        for subview in view.subviews where subview.frame.contains(location) {
            return
        }
        onDismiss?()
    }

    @objc private func handleAddressLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        UIPasteboard.general.string = "\(address):\(port)"
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)
    }
}
#endif
