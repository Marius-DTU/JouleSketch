import SwiftUI

/// Keys for settings stored in `UserDefaults` (via `@AppStorage`).
enum SettingsKey {
    static let background = "canvasBackground"
    static let customBackground = "customCanvasBackground"
    static let showGrid = "showGrid"
    static let resistorStyle = "resistorStyle"
    static let keyBindings = "keyBindings"
    static let pageWidth = "pageWidth"
    static let pageHeight = "pageHeight"
    /// Hides the computed values so the user can work them out themselves.
    static let studyMode = "studyMode"
}

// MARK: - Page

/// The size of the drawing sheet, in grid points.
enum PageSize {
    static let defaultWidth = 100
    static let defaultHeight = 100
    static let range = 10...1000
}

// MARK: - Background

/// The color of the drawing sheet.
enum CanvasBackground: String, CaseIterable, Identifiable {
    case system
    case paper
    case white
    case gray
    case dark
    case blueprint
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "Følg systemet (lys/mørk)"
        case .paper: "Papir"
        case .white: "Hvid"
        case .gray: "Grå"
        case .dark: "Mørk"
        case .blueprint: "Blueprint"
        case .custom: "Egen farve"
        }
    }
}

extension Color.Resolved {
    /// Whether light-colored lines are needed for contrast on this color.
    var isDark: Bool {
        // Components are in linear sRGB, as relative luminance expects.
        0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.18
    }

    /// Encodes the color for storage in `@AppStorage`.
    var storageString: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    init?(storageString: String) {
        guard let data = storageString.data(using: .utf8),
              let color = try? JSONDecoder().decode(Color.Resolved.self, from: data) else { return nil }
        self = color
    }

    static let defaultCustomBackground = Color.Resolved(red: 0.93, green: 0.95, blue: 0.9)
}

// MARK: - Symbols

/// How resistors are drawn.
enum ResistorStyle: String, CaseIterable, Identifiable {
    /// European (IEC 60617): a rectangle.
    case iec
    /// American (ANSI/IEEE): a zigzag.
    case ansi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iec: "Europæisk (rektangel)"
        case .ansi: "Amerikansk (zigzag)"
        }
    }
}

// MARK: - Keyboard shortcuts

/// Actions that can be bound to a single key on the drawing sheet.
enum KeyAction: String, CaseIterable, Identifiable, Codable {
    case select
    case wire
    case resistor
    case voltageSource
    case currentSource
    case diode
    case led
    case ground
    case current
    case probe
    case power
    case equivalent
    case text
    case mesh
    case groupArea
    case rotate
    case selectWholeWire
    /// ⌘-shortcuts used while typing in a text box.
    case textMode
    case mathMode
    case evaluateMath
    case unitBrackets

    var id: String { rawValue }

    /// Actions pressed together with ⌘ (while typing in a text box) rather
    /// than as a single key on the sheet.
    var usesCommand: Bool {
        switch self {
        case .textMode, .mathMode, .evaluateMath, .unitBrackets: true
        default: false
        }
    }

    /// Actions pressed with ⇧ as well as ⌘.
    var usesShift: Bool { self == .unitBrackets }

    /// The modifier keys shown before the key in the settings, e.g. "⌘⇧".
    var modifierSymbols: String {
        (usesCommand ? "⌘" : "") + (usesShift ? "⇧" : "")
    }

    var displayName: String {
        switch self {
        case .rotate: "Rotér / vend retning"
        case .selectWholeWire: "Markér hele ledningen"
        case .textMode: "Tekstfelt: tekst"
        case .mathMode: "Tekstfelt: math (LaTeX)"
        case .evaluateMath: "Tekstfelt: udregn"
        case .unitBrackets: "Tekstfelt: enhed [[ ]]"
        default: tool?.displayName ?? rawValue
        }
    }

    /// The tool this action selects, or `nil` for other actions.
    var tool: Tool? {
        switch self {
        case .select: .select
        case .wire: .wire
        case .resistor: .component(.resistor)
        case .voltageSource: .component(.voltageSource)
        case .currentSource: .component(.currentSource)
        case .diode: .component(.diode)
        case .led: .component(.led)
        case .ground: .ground
        case .current: .current
        case .probe: .probe
        case .power: .power
        case .equivalent: .equivalent
        case .text: .text
        case .mesh: .mesh
        case .groupArea: .groupArea
        case .rotate, .selectWholeWire, .textMode, .mathMode, .evaluateMath, .unitBrackets: nil
        }
    }

    var defaultKey: String {
        switch self {
        case .select: "s"
        case .wire: "w"
        case .resistor: "1"
        case .voltageSource: "2"
        case .currentSource: "3"
        case .diode: "4"
        case .led: "5"
        case .ground: "g"
        case .current: "i"
        case .probe: "p"
        case .power: "f"
        case .equivalent: "e"
        case .text: "t"
        case .mesh: "m"
        case .groupArea: "k"
        case .rotate: "r"
        case .selectWholeWire: "u"
        case .textMode: "t"
        case .mathMode: "m"
        case .evaluateMath: "b"
        case .unitBrackets: "u"
        }
    }
}

/// The user's key bindings. Actions without a custom key use their default.
struct KeyBindings: Codable, Equatable {
    private var keys: [KeyAction: String] = [:]

    subscript(action: KeyAction) -> String {
        get { keys[action] ?? action.defaultKey }
        set { keys[action] = newValue.lowercased() }
    }

    /// The action bound to a typed key, if any.
    func action(for key: String) -> KeyAction? {
        let key = key.lowercased()
        return KeyAction.allCases.first { !$0.usesCommand && !self[$0].isEmpty && self[$0] == key }
    }

    /// Actions sharing their key with another action.
    var conflicts: Set<KeyAction> {
        var result = Set<KeyAction>()
        for a in KeyAction.allCases {
            for b in KeyAction.allCases where a != b && a.modifierSymbols == b.modifierSymbols && !self[a].isEmpty && self[a] == self[b] {
                result.insert(a)
            }
        }
        return result
    }

    init() {}

    init(storageString: String) {
        if let data = storageString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(KeyBindings.self, from: data) {
            self = decoded
        }
    }

    var storageString: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

extension Tool {
    /// The key currently bound to this tool.
    func key(in bindings: KeyBindings) -> String {
        guard let action = KeyAction.allCases.first(where: { $0.tool == self }) else { return "" }
        return bindings[action]
    }
}

// MARK: - Settings view

/// App settings: appearance, page size, symbols and keyboard shortcuts.
/// Shown in the Settings window on Mac (⌘,) and as a sheet on iPad and iPhone.
struct SettingsView: View {
    @AppStorage(SettingsKey.background) private var background = CanvasBackground.paper
    @AppStorage(SettingsKey.customBackground) private var customBackground = ""
    @AppStorage(SettingsKey.showGrid) private var showGrid = true
    @AppStorage(SettingsKey.resistorStyle) private var resistorStyle = ResistorStyle.iec
    @AppStorage(SettingsKey.keyBindings) private var keyBindingsStorage = ""
    @AppStorage(SettingsKey.pageWidth) private var pageWidth = PageSize.defaultWidth
    @AppStorage(SettingsKey.pageHeight) private var pageHeight = PageSize.defaultHeight

    private var keyBindings: KeyBindings { KeyBindings(storageString: keyBindingsStorage) }

    var body: some View {
        Form {
            Section("Udseende") {
                Picker("Baggrund", selection: $background) {
                    ForEach(CanvasBackground.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                if background == .custom {
                    ColorPicker("Egen baggrundsfarve", selection: customColor, supportsOpacity: false)
                }
                Toggle("Vis gitterprikker", isOn: $showGrid)
            }

            Section {
                pageSizeRow("Bredde", value: $pageWidth)
                pageSizeRow("Højde", value: $pageHeight)
            } header: {
                Text("Side")
            } footer: {
                Text("Størrelsen måles i gitterpunkter.")
            }

            Section("Symboler") {
                Picker("Modstand", selection: $resistorStyle) {
                    ForEach(ResistorStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                LabeledContent("Eksempel") {
                    ToolIcon(tool: .component(.resistor))
                        .scaleEffect(1.6)
                        .frame(width: 60, height: 36)
                }
            }

            Section {
                ForEach(KeyAction.allCases) { action in
                    keyRow(for: action)
                }
                Button("Nulstil til standard") {
                    keyBindingsStorage = ""
                }
                .disabled(keyBindings == KeyBindings())
            } header: {
                Text("Tastaturgenveje")
            } footer: {
                Text("Genvejene virker, når tegnefladen er aktiv. Faste taster: Esc afslutter en ledning eller skifter til Vælg, Backspace sletter, ⌘A markerer alt, ⌘C kopierer, ⌘V indsætter ved markøren, ⌘-klik tilføjer eller fjerner fra markeringen, ⌘ + højretræk laver et område, der udelades af beregningen, ⇧-træk med Ledning tegner en firkant, ⌘Z fortryder.")
            }

        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 480)
        .navigationTitle("Indstillinger")
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { Color(Color.Resolved(storageString: customBackground) ?? .defaultCustomBackground) },
            set: { newColor in customBackground = newColor.resolve(in: EnvironmentValues()).storageString }
        )
    }

    /// A number field with a stepper for one side of the page.
    private func pageSizeRow(_ title: String, value: Binding<Int>) -> some View {
        let clamped = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(PageSize.range.upperBound, max(PageSize.range.lowerBound, $0)) }
        )
        return LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, value: clamped, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Stepper(title, value: clamped, in: PageSize.range, step: 10)
                    .labelsHidden()
            }
        }
    }

    private func keyRow(for action: KeyAction) -> some View {
        let isConflicting = keyBindings.conflicts.contains(action)
        return LabeledContent {
            HStack(spacing: 8) {
                if !action.modifierSymbols.isEmpty {
                    Text(action.modifierSymbols)
                        .foregroundStyle(.secondary)
                }
                if isConflicting {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Tasten bruges også af en anden handling")
                        .accessibilityLabel("Tasten bruges også af en anden handling")
                }
                TextField("Tast", text: keyBinding(for: action))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .autocorrectionDisabled()
                    .frame(width: 48)
            }
        } label: {
            Text(action.displayName)
        }
    }

    /// A binding that keeps only the last typed character, so typing
    /// a new key replaces the old one.
    private func keyBinding(for action: KeyAction) -> Binding<String> {
        Binding(
            get: { keyBindings[action].uppercased() },
            set: { newValue in
                var bindings = keyBindings
                bindings[action] = newValue.last.map { String($0) } ?? ""
                keyBindingsStorage = bindings.storageString
            }
        )
    }
}

#Preview {
    SettingsView()
}
