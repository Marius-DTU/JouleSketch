import SwiftUI

/// Shows and edits the properties of the selected item.
struct InspectorView: View {
    let editor: CircuitEditor

    @AppStorage(SettingsKey.studyMode) private var studyMode = false

    /// The computed values to show; none in study mode.
    private var solution: CircuitSolution { studyMode ? editor.solution.withoutValues : editor.solution }
    var body: some View {
        Form {
            switch editor.selection {
            case .component(let id):
                if let component = editor.component(id: id) {
                    componentSection(component)
                }
            case .probe(let id), .probeMinus(let id), .probeLabel(let id):
                if let probe = editor.probe(id: id) {
                    probeSection(probe)
                }
            case .wire:
                Section("Ledning") {
                    deleteButton
                }
            case .wireSegment(let id, _):
                Section("Ledningsstykke") {
                    Button("Markér hele ledningen (U)", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        editor.selection = .wire(id)
                    }
                    deleteButton
                }
            case .currentArrow(let id):
                if let arrow = editor.currentArrow(id: id) {
                    currentSection(arrow)
                }
            case .ground(let id):
                Section("Stel (0 V)") {
                    Text("Knudepunktet, stel-symbolet sidder på, er referencen på 0 V.")
                        .foregroundStyle(.secondary)
                    Button("Rotér (R)", systemImage: "rotate.right") {
                        editor.rotateGround(id: id)
                    }
                    deleteButton
                }
            case .sense(let id):
                if let marker = editor.circuit.senses.first(where: { $0.id == id }),
                   let owner = editor.component(id: marker.ownerID) {
                    senseSection(marker, owner: owner)
                }
            case .senseLabel(let id):
                if let owner = editor.component(id: id) {
                    Section("\(owner.controlLabel) for \(owner.name)") {
                        ControlNameField(editor: editor, component: owner)
                        Text("\(owner.controlLabel) sidder midt mellem + og − punkterne. Træk den ud til siden for at ændre afstanden, så den ikke dækker for andet.")
                            .foregroundStyle(.secondary)
                    }
                }
            case .equivalent(let id):
                if let equivalent = editor.equivalent(id: id) {
                    equivalentSection(equivalent)
                }
            case .textBox(let id):
                Section("Tekstfelt") {
                    Text("Dobbeltklik for at skrive. Linjer kan være tekst eller math (LaTeX); udregn en formel med ⌘B.")
                        .foregroundStyle(.secondary)
                    Button("Skriv i tekstfeltet", systemImage: "character.cursor.ibeam") {
                        editor.beginEditingTextBox(id: id)
                    }
                    deleteButton
                }
            case .meshMarker(let id):
                if let marker = editor.meshMarker(id: id) {
                    MeshMarkerSection(editor: editor, marker: marker)
                    Section { deleteButton }
                }
            case .excludedArea:
                Section("Udeladt område") {
                    Text("Det, der ligger helt inden for firkanten, er udeladt af autoberegningen og Maple-output. Træk i kanten for at flytte den; slet den for at tage indholdet med igen.")
                        .foregroundStyle(.secondary)
                    deleteButton
                }
            case .groupArea(let id):
                if let group = editor.groupArea(id: id) {
                    GroupAreaSection(editor: editor, group: group)
                    Section { deleteButton }
                }
            case .group(let items):
                Section("\(items.count) elementer markeret") {
                    deleteButton
                }
            case nil:
                Section {
                    Text("Vælg en komponent, ledning eller et spændingspunkt for at redigere det.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .presentationDetents([.medium, .large])
    }

    private func componentSection(_ component: CircuitComponent) -> some View {
        Section(component.kind.displayName) {
            TextField("Navn", text: Binding(
                get: { component.name },
                set: { newName in editor.updateComponent(id: component.id) { $0.name = newName } }
            ))

            ValueField(
                unit: component.kind.displayUnit, value: component.value,
                title: component.kind.valueTitle,
                allowsNegative: component.kind.allowsNegativeValue
            ) { newValue in
                editor.updateComponent(id: component.id) { $0.value = newValue }
            }
            .id(component.id)

            if component.kind.isDependent {
                DependentSourceControls(editor: editor, component: component)
            }

            if component.kind == .resistor,
               let resistance = component.value ?? solution.componentValues[component.id], resistance > 0 {
                ResistorColorCodeView(resistance: resistance)
            }

            if component.kind.isDiode, let conducts = solution.diodeConducts[component.id] {
                LabeledContent("Tilstand", value: conducts ? "Leder" : "Spærrer")
            }

            Toggle("Vis afsat effekt", isOn: Binding(
                get: { component.isPowerShown },
                set: { editor.setPowerShown($0, id: component.id) }
            ))
            if component.isPowerShown {
                LabeledContent("Effekt", value: SIValue.format(solution.powerValues[component.id], unit: "W"))
            }

            NoteField(text: Binding(
                get: { component.note },
                set: { newNote in editor.updateComponent(id: component.id) { $0.note = newNote } }
            ))

            Button("Rotér (R)", systemImage: "rotate.right") {
                editor.rotateComponent(id: component.id)
            }

            if component.kind != .resistor {
                Button("Vend retning", systemImage: "arrow.left.arrow.right") {
                    editor.flipComponent(id: component.id)
                }
            }

            deleteButton
        }
    }

    private func probeSection(_ probe: Probe) -> some View {
        Section(probe.isVoltageDrop ? "Spændingsfald (V(+) − V(−))" : "Spændingspunkt") {
            TextField("Navn", text: Binding(
                get: { probe.name },
                set: { newName in editor.updateProbe(id: probe.id) { $0.name = newName } }
            ))
            ValueField(unit: "V", value: probe.value) { newValue in
                editor.updateProbe(id: probe.id) { $0.value = newValue }
            }
            .id(probe.id)
            NoteField(text: Binding(
                get: { probe.note },
                set: { newNote in editor.updateProbe(id: probe.id) { $0.note = newNote } }
            ))
            if probe.isVoltageDrop {
                Button("Gør til almindeligt spændingspunkt", systemImage: "smallcircle.filled.circle") {
                    editor.selection = .probeMinus(probe.id)
                    editor.deleteSelection()
                    editor.selection = .probe(probe.id)
                }
            } else {
                Text("Hold ⌘ nede og træk fra punktet for at måle spændingsfaldet til et andet punkt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            deleteButton
        }
    }

    private func currentSection(_ arrow: CurrentArrow) -> some View {
        Section("Strøm i ledning") {
            TextField("Navn", text: Binding(
                get: { arrow.name },
                set: { newName in editor.updateCurrentArrow(id: arrow.id) { $0.name = newName } }
            ))
            ValueField(unit: "A", value: arrow.value) { newValue in
                editor.updateCurrentArrow(id: arrow.id) { $0.value = newValue }
            }
            .id(arrow.id)
            NoteField(text: Binding(
                get: { arrow.note },
                set: { newNote in editor.updateCurrentArrow(id: arrow.id) { $0.note = newNote } }
            ))
            Button("Vend retning (R)", systemImage: "arrow.left.arrow.right") {
                editor.flipCurrentArrow(id: arrow.id)
            }
            deleteButton
        }
    }

    private func equivalentSection(_ equivalent: EquivalentResistance) -> some View {
        let result = editor.equivalentResults[equivalent.id]
        let members = editor.circuit.components.filter { result?.resistors.contains($0.id) == true }
        return Section("Samlet modstand") {
            TextField("Navn", text: Binding(
                get: { equivalent.name },
                set: { newName in editor.updateEquivalent(id: equivalent.id) { $0.name = newName } }
            ))
            if studyMode {
                LabeledContent("Værdi", value: "Skjult i study mode")
            } else if case .value(let resistance, _) = result {
                LabeledContent("Værdi", value: SIValue.format(resistance, unit: "Ω"))
                LabeledContent("Består af", value: members.isEmpty ? "–" : members.map(\.name).formatted(.list(type: .and).locale(Locale(identifier: "da"))))
            } else {
                LabeledContent("Værdi", value: SIValue.format(nil, unit: "Ω"))
                Text(explanation(for: result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Modstanden set mellem de to punkter, med spændingskilder kortsluttet og strømkilder afbrudt. En kilde, der sidder direkte mellem punkterne, fjernes. Styrede kilder bliver tændt (Req = Voc/Isc), og dioder står i deres beregnede tilstand.")
                .font(.caption)
                .foregroundStyle(.secondary)
            deleteButton
        }
    }

    private func explanation(for result: EquivalentResult?) -> String {
        switch result {
        case .unknownValues(let names):
            "Værdien af \(names.formatted(.list(type: .and).locale(Locale(identifier: "da")))) kendes ikke endnu."
        case .dependentSources(let names):
            "\(names.formatted(.list(type: .and).locale(Locale(identifier: "da")))) indgår, men Req kan ikke findes. Tjek at styrede kilder har deres styrepunkter på kredsløbet."
        case .notConnected:
            "Der er ingen vej gennem modstande mellem de to punkter."
        case .notOnCircuit, .value, nil:
            "Et af punkterne sidder ikke længere på kredsløbet. Slet Req og sæt den igen."
        }
    }

    private func senseSection(_ marker: SenseMarker, owner: CircuitComponent) -> some View {
        Section(marker.kind == .current ? "\(owner.controlLabel) for \(owner.name)" : "\(owner.controlLabel)\(marker.kind == .plus ? "+" : "−") for \(owner.name)") {
            ControlNameField(editor: editor, component: owner)
            Text(marker.kind == .current
                 ? "Sæt punktet på den ledning, hvor den styrende strøm løber. R vender retningen."
                 : "Sæt punktet på det sted i kredsløbet, hvor \(owner.controlLabel) skal måles \(marker.kind == .plus ? "fra (+)" : "til (−)").")
                .foregroundStyle(.secondary)
            if marker.kind == .current {
                Button("Vend retning (R)", systemImage: "arrow.left.arrow.right") {
                    editor.flipSense(id: marker.id)
                }
            }
            Button("Vis \(owner.name)", systemImage: "arrow.right.circle") {
                editor.selection = .component(owner.id)
            }
        }
    }

    private var deleteButton: some View {
        Button("Slet", systemImage: "trash", role: .destructive) {
            editor.deleteSelection()
        }
    }
}

/// Chooses what controls a controlled source: the voltage between two voltage
/// points (Vs) or the current under a current arrow (Is).
struct DependentSourceControls: View {
    let editor: CircuitEditor
    let component: CircuitComponent

    var body: some View {
        LabeledContent("Sammenhæng", value: editor.circuit.controlDescription(of: component))
        ControlNameField(editor: editor, component: component)
        Text(hint)
            .font(.caption)
            .foregroundStyle(.secondary)
        if component.kind.isCurrentControlled, let marker = editor.circuit.sense(of: component.id, .current) {
            Button("Vend \(component.controlLabel)-retning (R)", systemImage: "arrow.left.arrow.right") {
                editor.flipSense(id: marker.id)
            }
        }
    }

    private var hint: String {
        if component.kind.isVoltageControlled {
            return "Træk + og − punkterne hen på de to steder, \(component.controlLabel) skal måles imellem. \"\(component.controlLabel)\"-teksten kan flyttes for sig."
        }
        let onWire = editor.circuit.sense(of: component.id, .current).flatMap { editor.circuit.currentArrow(for: $0) } != nil
        return onWire
            ? "\(component.controlLabel) måles i ledningen under \(component.controlLabel)-punktet, i pilens retning."
            : "Træk \(component.controlLabel)-punktet hen på den ledning, hvor den styrende strøm løber."
    }
}

/// The name of a controlled source's controlling voltage or current (Vs, Is).
/// Left empty, it's the default name.
struct ControlNameField: View {
    let editor: CircuitEditor
    let component: CircuitComponent

    private var defaultName: String { component.kind.isVoltageControlled ? "Vs" : "Is" }

    var body: some View {
        TextField("Navn på \(component.kind.isVoltageControlled ? "styrespænding" : "styrestrøm")", text: Binding(
            get: { component.controlName ?? "" },
            set: { newName in editor.updateComponent(id: component.id) { $0.controlName = newName.isEmpty ? nil : newName } }
        ), prompt: Text(defaultName))
    }
}

/// A text field for a component value that understands SI prefixes
/// ("4,7k", "10 mA"). Leaving it empty marks the value as unknown.
struct ValueField: View {
    let unit: String
    /// The field's label; "Værdi (unit)" if not given.
    var title: String?
    /// Resistances can't be negative.
    var allowsNegative = true
    let onChange: (Double?) -> Void

    @State private var text: String

    init(unit: String, value: Double?, title: String? = nil, allowsNegative: Bool = true, onChange: @escaping (Double?) -> Void) {
        self.unit = unit
        self.title = title
        self.allowsNegative = allowsNegative
        self.onChange = onChange
        _text = State(initialValue: value.map { SIValue.format($0, unit: unit) } ?? "")
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    private var isNegative: Bool { (SIValue.parse(text) ?? 0) < 0 }

    private var isValid: Bool {
        isEmpty || (SIValue.parse(text) != nil && (allowsNegative || !isNegative))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title ?? "Værdi (\(unit))", text: $text, prompt: Text("Ukendt – fx 4,7k"))
                .autocorrectionDisabled()
                .onChange(of: text) {
                    if isValid { onChange(SIValue.parse(text)) }
                }
            if !isValid {
                Text(isNegative && !allowsNegative ? "Kan ikke være negativ" : "Ugyldig værdi")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let standard = standardText, standard != text.trimmingCharacters(in: .whitespaces) {
                // Back to the standard unit, keeping the number: "3 mA/V" → "3 A/V".
                Button("Nulstil enhed til \(unit)", systemImage: "arrow.uturn.backward") {
                    text = standard
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    /// The typed number with the standard unit, or `nil` when there's no
    /// number or unit.
    private var standardText: String? {
        let number = SIValue.numberPart(of: text)
        guard !unit.isEmpty, !number.isEmpty, Double(number.replacingOccurrences(of: ",", with: ".")) != nil else { return nil }
        return "\(number) \(unit)"
    }
}

/// Name and direction of a mesh current, used by the mesh method.
struct MeshMarkerSection: View {
    let editor: CircuitEditor
    let marker: MeshMarker

    var body: some View {
        Section("Maskestrøm") {
            TextField("Navn", text: Binding(
                get: { marker.name },
                set: { newName in editor.updateMeshMarker(id: marker.id) { $0.name = newName } }
            ))
            Picker("Retning", selection: Binding(
                get: { marker.clockwise },
                set: { clockwise in editor.updateMeshMarker(id: marker.id) { $0.clockwise = clockwise } }
            )) {
                Text("Med uret").tag(true)
                Text("Mod uret").tag(false)
            }
            Text("Maskemetoden i Maple-gennemgangen bruger navnet og retningen for masken, pilen står i. R vender retningen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A group's name and tint.
struct GroupAreaSection: View {
    let editor: CircuitEditor
    let group: GroupArea

    @Environment(\.self) private var environment

    var body: some View {
        Section("Gruppe") {
            TextField("Navn", text: Binding(
                get: { group.name },
                set: { newName in editor.updateGroupArea(id: group.id) { $0.name = newName } }
            ))
            ColorPicker("Farve", selection: Binding(
                get: { Color(red: group.red, green: group.green, blue: group.blue) },
                set: { newColor in
                    guard let (red, green, blue) = sRGB(of: newColor) else { return }
                    editor.updateGroupArea(id: group.id) { $0.red = red; $0.green = green; $0.blue = blue }
                }
            ), supportsOpacity: false)
            Text("I Maple-vinduet kan du vælge gruppen og få output og gennemgang af det, der ligger helt inden for boksen. Træk i kanten eller navnet for at flytte den.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A color's red, green and blue in sRGB, from 0 to 1.
    private func sRGB(of color: Color) -> (Double, Double, Double)? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let components = color.resolve(in: environment).cgColor
                .converted(to: space, intent: .defaultIntent, options: nil)?.components,
              components.count >= 3 else { return nil }
        return (Double(components[0]), Double(components[1]), Double(components[2]))
    }
}

#Preview("Styret kilde") {
    let editor = CircuitEditor()
    editor.addProbe(at: GridPoint(x: 0, y: 0))
    editor.addProbe(at: GridPoint(x: 4, y: 0))
    editor.addComponent(.vcvs, from: GridPoint(x: 8, y: 4), to: GridPoint(x: 8, y: 0))
    let source = editor.circuit.components[0]
    editor.updateComponent(id: source.id) { $0.value = 2 }
    return InspectorView(editor: editor)
        .frame(width: 360, height: 520)
}
