import SwiftUI

/// Floating Liquid Glass palette for picking the active tool.
struct ToolPalette: View {
    let editor: CircuitEditor
    /// The width the window leaves for the palette. It's measured outside,
    /// since the palette's own frame grows with the buttons.
    let availableWidth: CGFloat

    @AppStorage(SettingsKey.keyBindings) private var keyBindingsStorage = ""
    /// The group whose menu is open.
    @State private var openGroup: ToolGroup?
    /// The buttons' size at full scale.
    @State private var naturalSize: CGSize = .zero
    /// Where the palette is scrolled to when it doesn't fit, and where a
    /// drag with the mouse began.
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollOffset: CGFloat = 0
    @State private var dragStartOffset: CGFloat?

    /// The coordinate space of the sheet the palette floats over.
    static let sheetSpace = "sheet"

    /// The buttons shrink only a little to fit; below this they keep their
    /// size and the palette scrolls instead.
    private static let minimumScale: CGFloat = 0.85

    /// How much the buttons shrink to fit inside the window.
    private var paletteScale: CGFloat {
        guard naturalSize.width > 0, availableWidth > 0 else { return 1 }
        return max(Self.minimumScale, min(1, availableWidth / naturalSize.width))
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(hint(for: editor.tool))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassBackground()

            GlassContainer {
                let scale = paletteScale
                let scaled = toolButtons
                    .padding(6)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { naturalSize = $0 }
                    .scaleEffect(scale)
                    // scaleEffect doesn't change the layout size, so the frame does.
                    .frame(
                        width: naturalSize == .zero ? nil : naturalSize.width * scale,
                        height: naturalSize == .zero ? nil : naturalSize.height * scale
                    )
                Group {
                    if naturalSize.width * scale > availableWidth + 0.5, availableWidth > 0 {
                        // Even at the smallest size it's too wide: scroll sideways.
                        ScrollView(.horizontal) { scaled }
                            .scrollIndicators(.hidden)
                            .scrollPosition($scrollPosition)
                            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scrollOffset = x }
                            #if os(macOS)
                            // A mouse can't scroll sideways, so the palette can be dragged too.
                            .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { value in
                                let start = dragStartOffset ?? scrollOffset
                                dragStartOffset = start
                                scrollPosition.scrollTo(x: max(0, start - value.translation.width))
                            }.onEnded { _ in dragStartOffset = nil })
                            #endif
                            .clipShape(Capsule())
                    } else {
                        scaled
                    }
                }
                .glassBackground()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.sheetSpace)) } action: { editor.paletteFrame = $0 }
                // In drawing mode the pen palette takes its place.
                .onDisappear { editor.paletteFrame = .zero }
            }
        }
        .frame(maxWidth: availableWidth)
    }

    private var toolButtons: some View {
        HStack(spacing: 4) {
            ForEach(ToolGroup.allCases) { group in
                groupButton(group)
            }
        }
    }

    /// A palette button. For a group with several tools it shows the one last
    /// used; clicking it again while it's picked opens the menu with the rest.
    private func groupButton(_ group: ToolGroup) -> some View {
        let tool = editor.shownTool(in: group)
        let isActive = editor.tool == tool
        return Button {
            if group.hasMenu, isActive {
                openGroup = group
            } else {
                pick(tool)
            }
        } label: {
            ToolIcon(tool: tool, color: isActive ? .white : .primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
                .background {
                    if isActive {
                        Capsule().fill(Color.accentColor)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if tool == .probe, isActive, editor.placesVoltageDrops {
                        Text("±")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.trailing, 3)
                    }
                }
                // A small corner mark shows that there's a menu.
                .overlay(alignment: .bottomTrailing) {
                    if group.hasMenu {
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(isActive ? .white : .secondary)
                            .padding(.trailing, 4)
                            .padding(.bottom, 4)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(group.hasMenu ? "\(helpText(for: tool)) · klik igen for \(group.title.lowercased())" : helpText(for: tool))
        .accessibilityLabel(group.hasMenu ? group.title : tool.displayName)
        .accessibilityValue(group.hasMenu ? tool.displayName : "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .contextMenu {
            if group.hasMenu {
                ForEach(group.tools) { item in
                    Button(item.displayName) { pick(item) }
                }
            }
        }
        // Opens upwards, above the palette.
        .popover(isPresented: Binding(
            get: { openGroup == group },
            set: { if !$0, openGroup == group { openGroup = nil } }
        ), arrowEdge: .bottom) {
            groupMenu(group)
        }
    }

    /// The tools of a group, with icon and name.
    private func groupMenu(_ group: ToolGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(group.tools) { tool in
                Button {
                    pick(tool)
                    openGroup = nil
                } label: {
                    HStack(spacing: 10) {
                        ToolIcon(tool: tool, color: editor.tool == tool ? .accentColor : .primary)
                        Text(tool.displayName)
                        Spacer(minLength: 12)
                        Text(tool.key(in: KeyBindings(storageString: keyBindingsStorage)).uppercased())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(helpText(for: tool))
                .accessibilityLabel(tool.displayName)
            }
        }
        .padding(8)
        .frame(minWidth: 240)
        .presentationCompactAdaptation(.popover)
    }

    private func pick(_ tool: Tool) {
        editor.tool = tool
        // ⌘-clicking the voltage point tool places voltage drops instead.
        if tool == .probe { editor.placesVoltageDrops = Self.isCommandHeld }
    }

    /// Whether ⌘ is held right now (Mac only).
    private static var isCommandHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }

    private func helpText(for tool: Tool) -> String {
        let key = tool.key(in: KeyBindings(storageString: keyBindingsStorage))
        return key.isEmpty ? tool.displayName : "\(tool.displayName) (\(key.uppercased()))"
    }

    private func hint(for tool: Tool) -> String {
        #if os(iOS)
        touchHint(for: tool)
        #else
        pointerHint(for: tool)
        #endif
    }

    /// Hints for touch screens, without keyboard shortcuts.
    private func touchHint(for tool: Tool) -> String {
        switch tool {
        case .select: "Tryk vælger · tryk to gange redigerer · træk markerer · to fingre flytter visningen"
        case .wire:
            editor.isRouting
                ? "Tryk for støttepunkt · tryk på et forbindelsespunkt eller samme punkt igen for at slutte"
                : "Tryk for at starte en ledning, eller træk fra punkt til punkt"
        case .component(.voltageSource): "Tryk for at placere · eller træk fra − til +"
        case .component(.currentSource): "Tryk for at placere · eller træk i strømmens retning"
        case .component(.diode), .component(.led): "Tryk for at placere · eller træk fra anode (+) til katode (−)"
        case .component(let kind) where kind.isDependent:
            "\(kind.displayName) (\(kind.setsVoltage ? "V" : "I") = \(kind.gainSymbol)·\(kind.isVoltageControlled ? "Vs" : "Is")) · vælg styringen i egenskaberne"
        case .component: "Tryk for at placere · eller træk mellem to punkter"
        case .ground: "Tryk for at placere stel (0 V)"
        case .current: "Tryk på en ledning for at angive strømmen · træk langs ledningen for at vælge retning"
        case .probe:
            editor.placesVoltageDrops
                ? "Træk fra + til − for at måle spændingsfaldet mellem to punkter"
                : "Tryk på en ledning for at indsætte et spændingspunkt"
        case .equivalent:
            editor.pendingEquivalentPoint == nil
                ? "Tryk på det første punkt (A) for den samlede modstand Req"
                : "Tryk på det andet punkt (B)"
        case .text: "Tryk for at indsætte et tekstfelt · tryk på et tekstfelt for at skrive i det"
        case .mesh: "Tryk inde i en maske for at vise dens maskestrøm og retning"
        case .power: "Tegn en cirkel om en komponent for at vise effekten i den · tryk på en komponent slår cirklen til og fra"
        case .groupArea: "Træk en boks om et kredsløb for at gøre det til en gruppe i Maple-vinduet"
        }
    }

    /// Hints for mouse and trackpad, with keyboard shortcuts.
    private func pointerHint(for tool: Tool) -> String {
        switch tool {
        case .select: "Klik vælger · ⌘-klik tilføjer · dobbeltklik redigerer · træk markerer · to fingre flytter visningen"
        case .wire:
            editor.isRouting
                ? "Klik for støttepunkt · klik på et forbindelsespunkt for at slutte · Esc afslutter"
                : "Klik for at starte en ledning · ⇧-træk tegner en firkant · Esc skifter til Vælg"
        case .component(.voltageSource): "Klik for at placere · R roterer · eller træk fra − til +"
        case .component(.currentSource): "Klik for at placere · R roterer · eller træk i strømmens retning"
        case .component(.diode), .component(.led): "Klik for at placere · R roterer · eller træk fra anode (+) til katode (−)"
        case .component(let kind) where kind.isDependent:
            "\(kind.displayName) (\(kind.setsVoltage ? "V" : "I") = \(kind.gainSymbol)·\(kind.isVoltageControlled ? "Vs" : "Is")) · vælg styringen i egenskaberne"
        case .component: "Klik for at placere · R roterer · eller træk mellem to punkter"
        case .ground: "Klik for at placere stel (0 V) · R roterer"
        case .current: "Tryk på en ledning for at angive strømmen · træk langs ledningen for at vælge retning · R vender"
        case .probe:
            editor.placesVoltageDrops
                ? "Træk fra + til − for at måle spændingsfaldet mellem to punkter"
                : "Klik på en ledning for at indsætte et spændingspunkt · ⌘-klik på værktøjet eller ⌘-træk fra et punkt: spændingsfald"
        case .equivalent:
            editor.pendingEquivalentPoint == nil
                ? "Klik på det første punkt (A) for den samlede modstand Req"
                : "Klik på det andet punkt (B) · Esc fortryder"
        case .power:
            "Træk en cirkel om en eller flere komponenter for at vise den afsatte effekt · klik på en komponent slår cirklen til og fra"
        case .mesh:
            "Klik inde i en maske for at vise maskestrømmen (\(editor.meshPlacementClockwise ? "med uret" : "mod uret")) · R vender retningen"
        case .groupArea:
            "Træk en boks om et kredsløb for at gøre det til en gruppe i Maple-vinduet · dobbeltklik på navnet for at omdøbe"
        case .text:
            "Klik for at indsætte et tekstfelt · \(commandHint(.textMode)) tekst · \(commandHint(.mathMode)) math (LaTeX) · \(commandHint(.evaluateMath)) udregner · \(commandHint(.unitBrackets)) enhed"
        }
    }

    /// A ⌘ shortcut from the key bindings, e.g. "⌘M".
    private func commandHint(_ action: KeyAction) -> String {
        action.modifierSymbols + KeyBindings(storageString: keyBindingsStorage)[action].uppercased()
    }
}

/// Pen colors and sizes, shown instead of the tools in drawing mode.
struct PenPalette: View {
    let editor: CircuitEditor

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SettingsKey.background) private var background = CanvasBackground.paper
    @AppStorage(SettingsKey.customBackground) private var customBackground = ""

    private static let colorNames = ["Sort", "Rød", "Grøn", "Orange", "Lilla"]
    private static let sizeNames = ["Meget tynd", "Tynd", "Mellem", "Tyk", "Meget tyk"]

    private var theme: SchematicTheme {
        SchematicTheme(
            background: background,
            customColor: Color.Resolved(storageString: customBackground) ?? .defaultCustomBackground,
            colorScheme: colorScheme
        )
    }

    var body: some View {
        GlassContainer {
            HStack(spacing: 10) {
                ForEach(0..<Stroke.colorCount, id: \.self) { index in
                    penButton(isActive: !editor.isErasing && editor.penColor == index, label: Self.colorNames[index]) {
                        editor.penColor = index
                    } content: {
                        Circle()
                            .fill(theme.penColor(index))
                            .frame(width: 18, height: 18)
                    }
                }
                Divider().frame(height: 22)
                ForEach(Stroke.widths.indices, id: \.self) { index in
                    penButton(isActive: !editor.isErasing && editor.penSize == index, label: Self.sizeNames[index]) {
                        editor.penSize = index
                    } content: {
                        Circle()
                            .fill(theme.penColor(editor.penColor))
                            .frame(width: Stroke.widths[index] + 3, height: Stroke.widths[index] + 3)
                            .frame(width: 18, height: 18)
                    }
                }
                Divider().frame(height: 22)
                penButton(isActive: editor.isErasing, label: "Viskelæder (hold ⌘ for at slette hele streger)") {
                    editor.isErasing.toggle()
                } content: {
                    Image(systemName: "eraser")
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassBackground()
        }
    }

    /// A round button with a ring around it while it's picked.
    private func penButton(
        isActive: Bool, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> some View
    ) -> some View {
        Button(action: action) {
            content()
                .padding(5)
                .overlay {
                    if isActive {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Wraps content in a `GlassEffectContainer` where Liquid Glass is available.
private struct GlassContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

private extension View {
    /// Liquid Glass capsule on iOS/macOS 26+, a material capsule on older systems.
    @ViewBuilder
    func glassBackground() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect()
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }
}
