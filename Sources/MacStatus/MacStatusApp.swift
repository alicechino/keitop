import SwiftUI

@main
struct KeiTopApp: App {
    @StateObject private var monitor = SystemMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(monitor)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)

        Window("KeiTop OSD", id: "osd") {
            OSDView()
                .environmentObject(monitor)
                .frame(width: 320, height: 168)
                .background(.ultraThinMaterial)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
