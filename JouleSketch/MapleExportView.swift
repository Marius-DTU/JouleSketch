import SwiftUI

/// The calculation step by step, by the method picked at the top
/// (node voltages, mesh currents or superposition), with buttons to copy the
/// same method as Maple code.
struct MapleExportView: View {
    /// The whole document; `circuit` is what's worked with.
    let document: Circuit

    init(circuit: Circuit) {
        document = circuit
    }

    @Environment(\.dismiss) private var dismiss
    /// Which copy button was used last, for its checkmark.
    @State private var copied: CopyKind?

    private enum CopyKind {
        /// MathML, which Maple reads as 2-D Math with lowered names.
        case maple
        case text
    }
    /// `nil` until chosen: the first method that works.
    @State private var method: WalkMethod?
    /// The group whose contents are worked with; `nil` for the whole document.
    @State private var groupID: UUID?

    /// The chosen group's contents, or the whole document.
    private var circuit: Circuit {
        guard let group = document.groupAreas.first(where: { $0.id == groupID }) else { return document }
        return document.inside(group)
    }

    /// Every method's walkthrough, worked out once for the circuit.
    private var results: [WalkMethod: WalkResult] {
        Dictionary(uniqueKeysWithValues: WalkMethod.allCases.map { ($0, Walkthrough.make($0, for: circuit)) })
    }

    /// The Maple code for a method, or `nil` if there is none. The
    /// node-voltage method has its own exporter, which handles more kinds of
    /// circuits than the walkthrough (unknown components, diodes).
    private func maple(_ method: WalkMethod, _ result: WalkResult?) -> String? {
        if method == .nodal { return MapleExporter.export(circuit) }
        if case .steps(_, let code?)? = result { return code }
        return nil
    }

    private func isAvailable(_ method: WalkMethod, _ results: [WalkMethod: WalkResult]) -> Bool {
        if case .steps = results[method] { return true }
        return method == .nodal
    }

    var body: some View {
        let results = results
        let shown = method ?? WalkMethod.allCases.first { if case .steps = results[$0] { true } else { false } } ?? .nodal
        let code = maple(shown, results[shown])
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Metode", selection: Binding(get: { shown }, set: { method = $0; copied = nil })) {
                    ForEach(WalkMethod.allCases) { option in
                        Text(isAvailable(option, results) ? option.title : "\(option.title) (ikke mulig)").tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top])

                if !document.groupAreas.isEmpty {
                    Picker("Gruppe", selection: Binding(get: { groupID }, set: { groupID = $0; copied = nil })) {
                        Text("Hele dokumentet").tag(UUID?.none)
                        Divider()
                        ForEach(document.groupAreas) { group in
                            Text(group.name.isEmpty ? "Unavngiven gruppe" : group.name).tag(UUID?.some(group.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .padding(.top, 8)
                }

                Spacer().frame(height: 16)

                Divider()

                if let result = results[shown] {
                    WalkthroughView(method: shown, result: result)
                        .safeAreaInset(edge: .bottom) {
                            if code != nil {
                                #if !os(iOS)
                                Text("Kopiér til Maple og indsæt i en Maple-worksheet: beregningen kommer ind som 2-D Math med sænkede navne og brøker. Tryk Enter for at regne. Kopiér som tekst giver almindelig Maple-input med kommentarer.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.bar)
                                #endif
                            }
                        }
                }
            }
            .navigationTitle("Gennemgang – \(shown.title.lowercased())")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Luk") { dismiss() }
                }
                // Maple is on the Mac; on iOS only the walkthrough is shown.
                #if !os(iOS)
                if let code {
                    ToolbarItem(placement: .primaryAction) {
                        Button(copied == .text ? "Kopieret" : "Kopiér som tekst", systemImage: copied == .text ? "checkmark" : "doc.plaintext") {
                            copyToClipboard(code)
                            copied = .text
                        }
                        .help("Almindelig tekst (Maple-input), fx til en teksteditor")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(copied == .maple ? "Kopieret" : "Kopiér til Maple", systemImage: copied == .maple ? "checkmark" : "doc.on.doc") {
                            copyToClipboard(MapleMathML.convert(code))
                            copied = .maple
                        }
                        .help("Som 2-D Math, så sænkede navne og brøker står pænt i Maple")
                    }
                }
                #endif
            }
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

#Preview {
    var circuit = Circuit()
    circuit.components = [
        CircuitComponent(kind: .voltageSource, start: GridPoint(x: 0, y: 4), end: GridPoint(x: 0, y: 0), name: "V1", value: 12),
        CircuitComponent(kind: .resistor, start: GridPoint(x: 0, y: 0), end: GridPoint(x: 4, y: 0), name: "R2", value: 100),
        CircuitComponent(kind: .resistor, start: GridPoint(x: 4, y: 0), end: GridPoint(x: 4, y: 4), name: "R1", value: 50),
    ]
    circuit.wires = [Wire(points: [GridPoint(x: 4, y: 4), GridPoint(x: 0, y: 4)])]
    circuit.grounds = [Ground(position: GridPoint(x: 0, y: 4))]
    circuit.probes = [Probe(position: GridPoint(x: 0, y: 0), name: "VB"), Probe(position: GridPoint(x: 4, y: 0), name: "VA")]
    return MapleExportView(circuit: circuit)
}
