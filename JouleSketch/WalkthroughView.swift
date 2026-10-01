import SwiftUI

/// Step by step, how the missing voltages and currents are found with the
/// node-voltage method, the mesh-current method or superposition.
/// The method is chosen by the view showing it.
struct WalkthroughView: View {
    let method: WalkMethod
    let result: WalkResult

    var body: some View {
        switch result {
        case .steps(let sections, _):
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .unavailable(let reason):
            ContentUnavailableView {
                Label("\(method.title)smetoden kan ikke bruges", systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            }
        }
    }

    private func sectionView(_ section: WalkSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.headline)
            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .text(let text):
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560, alignment: .leading)
                case .math(let latex):
                    MathRowView(row: LatexParser.parse(latex), size: 16)
                        .padding(.leading, 12)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

#Preview {
    var circuit = Circuit()
    circuit.components = [
        CircuitComponent(kind: .voltageSource, start: GridPoint(x: 0, y: 8), end: GridPoint(x: 0, y: 0), name: "S1", value: 12),
        CircuitComponent(kind: .resistor, start: GridPoint(x: 0, y: 0), end: GridPoint(x: 8, y: 0), name: "R1", value: 1000),
        CircuitComponent(kind: .resistor, start: GridPoint(x: 8, y: 0), end: GridPoint(x: 8, y: 8), name: "R2", value: 2000),
        CircuitComponent(kind: .resistor, start: GridPoint(x: 8, y: 0), end: GridPoint(x: 16, y: 0), name: "R3", value: 1000),
        CircuitComponent(kind: .voltageSource, start: GridPoint(x: 16, y: 8), end: GridPoint(x: 16, y: 0), name: "S2", value: 6),
    ]
    circuit.wires = [Wire(points: [GridPoint(x: 0, y: 8), GridPoint(x: 8, y: 8), GridPoint(x: 16, y: 8)])]
    circuit.grounds = [Ground(position: GridPoint(x: 0, y: 8))]
    circuit.probes = [Probe(position: GridPoint(x: 8, y: 0), name: "VA")]
    return WalkthroughView(method: .nodal, result: Walkthrough.make(.nodal, for: circuit))
        .frame(width: 640, height: 720)
}
