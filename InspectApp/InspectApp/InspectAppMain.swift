import SwiftUI

@main
struct InspectAppMain: App {
    @StateObject private var model = InspectAppModel()

    var body: some Scene {
        WindowGroup("swift-inspector") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear { model.startBrowsing() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
