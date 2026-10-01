# JouleSketch

A circuit sketching app for Mac/iPad (SwiftUI, `JouleSketch.xcodeproj`) with a
web version for Windows (`Web/`, built with `Package.swift`).

## Every change goes into both versions

The web version compiles the shared Swift files listed in `Package.swift`
(`sharedFiles`) to WebAssembly. When fixing or adding something:

- **Logic belongs in the shared files** (circuit, solver, walkthroughs, Maple,
  `CircuitEditor`, `SheetInteraction`, `SchematicScene`, `KeyBindings`), not in
  SwiftUI views or the web page, so both versions get it at once.
- Shared files must stay free of SwiftUI/AppKit/UIKit: import `Foundation`
  (and `Observation`), and CoreGraphics only as
  `#if canImport(CoreGraphics) import CoreGraphics #endif`.
- The Mac canvas (`SchematicCanvas.swift`, `SymbolRenderer.swift`) still has
  its own drawing and gesture code. A change to drawing or gestures must be
  made in **both** `SchematicCanvas`/`SymbolRenderer` and
  `SchematicScene`/`SheetInteraction` until the Mac canvas is moved over to
  the shared ones.
- UI around the sheet (palette, symbol editor, dialogs, text boxes) exists
  twice: SwiftUI views and `Web/app/src/main.ts`. Update both.
- New bridge functions go in `Web/Bridge/main.swift` (`@JS`), and their
  signatures in the `JouleApp` interface at the top of `main.ts`.
- New shortcuts are `KeyAction`s (rebindable in settings) in both versions.

## Checking

- Mac: build with Xcode (BuildProject).
- Shared code compiles without SwiftUI:
  `cd JouleSketch && xcrun swiftc -typecheck -module-cache-path /tmp/jmc -swift-version 5 -enable-upcoming-feature MemberImportVisibility <shared files>`
- Web: `Web/build.sh` (needs the swift.org toolchain with the Wasm SDK and
  Node.js; see `Web/README.md`).
