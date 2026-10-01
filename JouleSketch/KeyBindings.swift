import Foundation

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
