import SwiftUI

/// Picks the app for the running system: the new document API on
/// iOS/macOS 27 and later, `ReferenceFileDocument` on older systems.
@main enum AppLauncher {
    static func main() {
        if #available(iOS 27.0, macOS 27.0, *) {
            MyApp.main()
        } else {
            LegacyApp.main()
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct MyApp: App {
    var body: some Scene {
        #if os(iOS)
        // Start screen on iPad and iPhone: the system document browser with
        // "Seneste" (recently opened), folders and iCloud, plus a new-file button.
        DocumentGroupLaunchScene("JouleSketch") {
            NewDocumentButton("Nyt kredsløb")
        }
        #endif

        DocumentGroup { document in
            ContentView(editor: document.editor)
        } makeDocument: { _, _ in
            CircuitDocument()
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

struct LegacyApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { LegacyCircuitDocument() }) { file in
            ContentView(editor: file.document.editor)
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
