import SwiftUI

/// A symbol whose editor is open, and where on screen to anchor it.
struct SymbolEditTarget: Identifiable {
    let item: Selection
    let anchor: CGRect
    var id: Selection { item }
}

/// Editor shown when double-clicking a symbol: name, value and a note.
struct SymbolEditorView: View {
    let editor: CircuitEditor
    let item: Selection

    @AppStorage(SettingsKey.studyMode) private var studyMode = false

    /// The computed values to show; none in study mode.
    private var solution: CircuitSolution { studyMode ? editor.solution.withoutValues : editor.solution }
    @Environment(\.dismiss) private var dismiss
    /// The value field gets focus when the editor opens, so a new value can be typed right away.
    @FocusState private var isValueFocused: Bool

    var body: some View {
        Form {
            switch item {
            case .component(let id):
                if let component = editor.component(id: id) {
                    Section(component.kind.displayName) {
                        TextField("Navn", text: Binding(
                            get: { component.name },
                            set: { newName in editor.updateComponent(id: id) { $0.name = newName } }
                        ))
                        .onSubmit { dismiss() }

                        if component.kind.isSwitch {
                            SwitchStateField(editor: editor, component: component)
                        } else {
                            ValueField(
                                unit: component.kind.displayUnit, value: component.value,
                                title: component.valueTitle,
                                allowsNegative: component.kind.allowsNegativeValue
                            ) { newValue in
                                editor.updateComponent(id: id) { $0.value = newValue }
                            }
                            .focused($isValueFocused)
                            .onSubmit { dismiss() }
                        }

                        if component.kind.isDependent {
                            DependentSourceControls(editor: editor, component: component)
                        }
                        if component.kind == .signalGenerator {
                            SignalGeneratorFields(editor: editor, component: component)
                        }
                    }
                    if component.kind == .resistor,
                       let resistance = component.value ?? solution.componentValues[component.id], resistance > 0 {
                        Section("Standardværdi og farvekode") {
                            ResistorColorCodeView(resistance: resistance)
                        }
                    }
                    Section("Note") {
                        NoteField(text: Binding(
                            get: { component.note },
                            set: { newNote in editor.updateComponent(id: id) { $0.note = newNote } }
                        ))
                    }
                }
            case .probe(let id):
                if let probe = editor.probe(id: id) {
                    Section("Spændingspunkt") {
                        TextField("Navn", text: Binding(
                            get: { probe.name },
                            set: { newName in editor.updateProbe(id: id) { $0.name = newName } }
                        ))
                        .onSubmit { dismiss() }

                        ValueField(unit: "V", value: probe.value) { newValue in
                            editor.updateProbe(id: id) { $0.value = newValue }
                        }
                        .focused($isValueFocused)
                        .onSubmit { dismiss() }
                    }
                    Section("Note") {
                        NoteField(text: Binding(
                            get: { probe.note },
                            set: { newNote in editor.updateProbe(id: id) { $0.note = newNote } }
                        ))
                    }
                }
            case .currentArrow(let id):
                if let arrow = editor.currentArrow(id: id) {
                    Section("Strøm i ledning") {
                        TextField("Navn", text: Binding(
                            get: { arrow.name },
                            set: { newName in editor.updateCurrentArrow(id: id) { $0.name = newName } }
                        ))
                        .onSubmit { dismiss() }

                        ValueField(unit: "A", value: arrow.value) { newValue in
                            editor.updateCurrentArrow(id: id) { $0.value = newValue }
                        }
                        .focused($isValueFocused)
                        .onSubmit { dismiss() }

                        Button("Vend retning", systemImage: "arrow.left.arrow.right") {
                            editor.updateCurrentArrow(id: id) { $0.forward.toggle() }
                        }
                    }
                    Section("Note") {
                        NoteField(text: Binding(
                            get: { arrow.note },
                            set: { newNote in editor.updateCurrentArrow(id: id) { $0.note = newNote } }
                        ))
                    }
                }
            case .meshMarker(let id):
                if let marker = editor.meshMarker(id: id) {
                    MeshMarkerSection(editor: editor, marker: marker)
                }
            case .groupArea(let id):
                if let group = editor.groupArea(id: id) {
                    GroupAreaSection(editor: editor, group: group)
                }
            case .sense(let id):
                if let owner = editor.circuit.senses.first(where: { $0.id == id }).flatMap({ editor.component(id: $0.ownerID) }) {
                    Section("\(owner.controlLabel) for \(owner.name)") {
                        ControlNameField(editor: editor, component: owner)
                            .onSubmit { dismiss() }
                    }
                }
            case .senseLabel(let id):
                if let owner = editor.component(id: id) {
                    Section("\(owner.controlLabel) for \(owner.name)") {
                        ControlNameField(editor: editor, component: owner)
                            .onSubmit { dismiss() }
                    }
                }
            default:
                EmptyView()
            }

            Section {
                Button("Færdig") { dismiss() }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 300, idealWidth: 320, minHeight: 300)
        .presentationDetents([.medium, .large])
        .defaultFocus($isValueFocused, true)
        .onAppear {
            editor.beginEdit()
            isValueFocused = true
        }
        .onDisappear { editor.endEdit() }
    }
}

/// A multi-line text field for notes.
struct NoteField: View {
    @Binding var text: String

    var body: some View {
        TextField("Note", text: $text, prompt: Text("Skriv en note…"), axis: .vertical)
            .lineLimit(3...8)
            .labelsHidden()
    }
}

#Preview {
    let editor = CircuitEditor()
    editor.addComponent(.resistor, from: GridPoint(x: 0, y: 0), to: GridPoint(x: 4, y: 0))
    let id = editor.circuit.components[0].id
    editor.updateComponent(id: id) {
        $0.value = 4700
        $0.note = "Formodstand til LED"
    }
    return SymbolEditorView(editor: editor, item: .component(id))
}
