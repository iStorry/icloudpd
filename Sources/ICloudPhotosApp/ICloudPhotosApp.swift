#if canImport(SwiftUI) && os(macOS)
import AppKit
import SwiftUI

@main
struct ICloudPhotosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    /// The menu bar extra writes its visibility back every time the scene updates. Passing that
    /// straight to the published property republishes an unchanged value, which updates the scene
    /// again: an endless loop that pins the main thread and stalls sign-in. So drop no-op writes.
    private var menuBarInserted: Binding<Bool> {
        Binding(get: { model.showInMenuBar },
                set: { if $0 != model.showInMenuBar { model.showInMenuBar = $0 } })
    }

    var body: some Scene {
        Window("iCloud Photos Downloader", id: "main") {
            RootView().environmentObject(model)
        }
        // No title bar: the dark content runs edge to edge, with the traffic lights over it.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 680)

        Settings {
            SettingsView().environmentObject(model)
        }

        MenuBarExtra("iCloud Photos", systemImage: model.isDownloading ? "icloud.and.arrow.down.fill" : "icloud.and.arrow.down",
                     isInserted: menuBarInserted) {
            MenuBarContent().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` instead of from an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// With the menu bar extra on, closing the window keeps scheduled downloads running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true)
    }
}
#else
// The app is macOS-only; this keeps `swift build` working on Linux, where only ICloudKit and its tests matter.
@main
enum ICloudPhotosApp {
    static func main() { print("The ICloudPhotos app needs macOS 26 or later.") }
}
#endif
