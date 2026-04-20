import SwiftUI

@main
struct InspectAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = InspectAppModel()

    var body: some Scene {
        WindowGroup("swift-inspector") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    model.startBrowsing()
                    appDelegate.model = model
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: InspectAppModel?

    func applicationWillTerminate(_ notification: Notification) {
        // Ensure cleanup runs on MainActor synchronously before the process exits
        let model = self.model
        MainActor.assumeIsolated {
            model?.shutdown()
        }
    }
}
