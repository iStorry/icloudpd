#if canImport(SwiftUI) && os(macOS)
import AppKit
import SwiftUI

/// Where the window's close, minimise and zoom buttons go: inside the top-left panel, with room
/// around them, instead of in the window's corner where they would sit on the panel's edge.
enum WindowButtons {
    /// The gap between the window's edges and the panels.
    static let margin: CGFloat = 10
    /// The close button's top-left corner, from the window's top-left corner.
    static let origin = CGPoint(x: margin + 14, y: margin + 12)
    /// How far down a panel in the corner starts its content, to clear the buttons.
    static let clearance: CGFloat = 40
}

/// Moves the window buttons to `WindowButtons.origin`. AppKit lays them out again when the window
/// resizes, changes screen or leaves full screen, so they are moved back each time.
struct WindowButtonsPlacer: NSViewRepresentable {
    func makeNSView(context: Context) -> PlacerView { PlacerView() }
    func updateNSView(_ view: PlacerView, context: Context) { view.place() }

    final class PlacerView: NSView {
        private var observers: [NSObjectProtocol] = []
        /// The buttons' own spacing, read once before they are moved.
        private var spacing: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            place()
            // The title bar is laid out after the first pass: move them again once it has been.
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func place() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let minimise = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let container = close.superview?.superview else { return }
            let spacing = spacing ?? (minimise.frame.minX - close.frame.minX)
            self.spacing = spacing

            // The title bar container holds the buttons; make it tall enough for them to move down.
            let origin = WindowButtons.origin
            let height = origin.y + close.frame.height + 4
            container.frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
            for (index, button) in [close, minimise, zoom].enumerated() {
                // The container counts up from its bottom edge.
                button.setFrameOrigin(NSPoint(x: origin.x + CGFloat(index) * spacing, y: 4))
            }
        }
    }
}
#endif
