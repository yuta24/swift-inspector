import SwiftUI
import InspectCore

/// "Connect by IP" sheet for environments where Bonjour discovery is
/// blocked (corp Wi-Fi with client isolation, guest networks, locked-
/// down conference rooms). The user reads `192.168.1.42:8765` off the
/// device's debug overlay and types it here; on submit the entry is
/// added to `AppInspectorModel.manualEndpoints` and immediately staged
/// as the active selection so a single Connect press goes straight
/// into the existing pair / handshake flow.
struct ManualEndpointSheet: View {
    @EnvironmentObject var model: AppInspectorModel
    @Environment(\.dismiss) private var dismiss

    @State private var hostInput: String = ""
    @State private var portInput: String = ""
    @State private var validationError: String?

    /// Most TestFlight builds default to a non-privileged ephemeral
    /// port chosen by NWListener; surfacing a hint here saves users
    /// from wondering what to type when no port shows on the device.
    private static let portPlaceholder = "8765"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect by IP")
                    .font(.headline)
                Text("Enter the host and port shown on the device's debug overlay. Use this when Bonjour discovery is blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Host or IP", text: $hostInput, prompt: Text("192.168.1.42"))
                TextField("Port", text: $portInput, prompt: Text(verbatim: Self.portPlaceholder))
            }
            .formStyle(.grouped)

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isInputValid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var isInputValid: Bool {
        let trimmedHost = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return false }
        return parsedPort != nil
    }

    /// Accepts a 1–65535 integer. Returns nil for any other input so
    /// `Connect` stays disabled until the user types a valid port.
    private var parsedPort: UInt16? {
        let trimmed = portInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt16(trimmed), value > 0 else { return nil }
        return value
    }

    private func submit() {
        let host = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            validationError = String(localized: "Host is required.")
            return
        }
        guard let port = parsedPort else {
            validationError = String(localized: "Port must be 1–65535.")
            return
        }
        guard let id = model.addManualEndpoint(host: host, port: port) else {
            validationError = String(localized: "Couldn't construct endpoint from input.")
            return
        }
        // Stage as the active selection so the existing Connect button
        // in the sidebar handles the actual NWConnection lifecycle.
        // Connecting from inside the sheet would split the connection
        // path and complicate cancellation while the sheet is still up.
        model.selectedEndpointID = id
        if let endpoint = model.manualEndpoints.first(where: { $0.id == id }) {
            model.connect(to: endpoint)
        }
        dismiss()
    }
}
