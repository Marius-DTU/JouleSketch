#if os(macOS)
import AppKit
import SwiftUI

/// Opens every circuit document as a tab in the same window, with the tab bar
/// always showing, like a text editor with several files open. Tabs can
/// still be dragged out into windows of their own.
///
/// Also keeps the window clear of the Dock: showing the tab bar makes the
/// window taller downwards, and sheets (the walkthrough) can move it, so a
/// window filling the screen could end up partly under the Dock.
struct DocumentTabs: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TabbingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TabbingView: NSView {
        static let tabbingIdentifier = "JouleSketchDocument"

        private var observers: [NSObjectProtocol] = []
        /// The window's frame when a sheet opened, put back when it closes.
        private var frameBeforeSheet: NSRect?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observe(window)
            guard let window else { return }
            window.tabbingMode = .preferred
            window.tabbingIdentifier = Self.tabbingIdentifier

            // Once the window is on screen: join the other documents if the
            // system didn't already, and show the tab bar even with one tab.
            DispatchQueue.main.async {
                if window.tabbedWindows == nil,
                   let other = NSApp.windows.first(where: {
                       $0 !== window && $0.isVisible && $0.tabbingIdentifier == Self.tabbingIdentifier
                   }) {
                    other.addTabbedWindow(window, ordered: .above)
                    window.makeKeyAndOrderFront(nil)
                }
                if let group = window.tabGroup, !group.isTabBarVisible {
                    window.toggleTabBar(nil)
                }
                Self.keepAboveDock(window)
            }
        }

        private func observe(_ window: NSWindow?) {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        self.frameBeforeSheet = window.frame
                    }
                },
                center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let frame = self.frameBeforeSheet else { return }
                        self.frameBeforeSheet = nil
                        // After AppKit is done with the sheet, so it can't move it again.
                        DispatchQueue.main.async {
                            guard let window = self.window, !window.styleMask.contains(.fullScreen),
                                  window.frame != frame else { return }
                            window.setFrame(frame, display: true, animate: false)
                            Self.keepAboveDock(window)
                        }
                    }
                },
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let window = self?.window else { return }
                        Self.keepAboveDock(window)
                    }
                },
            ]
        }

        /// A window reaching from the top of the screen down under the Dock
        /// (filling the screen, e.g. dragged to the top edge) is made to end
        /// where the Dock begins. Windows the user has placed lower are left alone.
        private static func keepAboveDock(_ window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen), let visible = window.screen?.visibleFrame else { return }
            var frame = window.frame
            guard abs(frame.maxY - visible.maxY) < 2, frame.minY < visible.minY - 0.5 else { return }
            frame.size.height = frame.maxY - visible.minY
            frame.origin.y = visible.minY
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
#endif
