#if canImport(SwiftUI) && os(macOS)
import AppKit
import SwiftUI

@main
struct ICloudPhotosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("iCloud Photos Downloader") {
            RootView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` instead of from an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#else
// The app is macOS-only; this keeps `swift build` working on Linux, where only ICloudKit and its tests matter.
@main
enum ICloudPhotosApp {
    static func main() { print("The ICloudPhotos app needs macOS 14 or later.") }
}
#endif
