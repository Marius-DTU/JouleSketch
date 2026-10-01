import SwiftUI

/// Explains the automatic calculation: how much could be computed, and
/// what's missing or contradictory.
struct SolverReportView: View {
    let solution: CircuitSolution

    var body: some View {
        List {
            Section {
                Label(summary, systemImage: CircuitSolution.symbol(for: solution))
                    .foregroundStyle(summaryColor)
            } footer: {
                Text("Beregnede værdier vises med grå kursiv på tegningen.")
            }

            if !solution.issues.isEmpty {
                Section("Det mangler / skal tjekkes") {
                    ForEach(solution.issues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(issue.title, systemImage: symbol(for: issue.kind))
                                .font(.headline)
                                .foregroundStyle(color(for: issue.kind))
                            Text(issue.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .frame(minWidth: 340, idealWidth: 380, minHeight: 240, idealHeight: 360)
        .presentationDetents([.medium, .large])
        .presentationCompactAdaptation(.sheet)
    }

    private var summary: String {
        if !solution.isConsistent { return "De kendte værdier passer ikke sammen" }
        if solution.unknownCount == 0 { return "Ingen ukendte værdier at beregne" }
        if solution.solvedCount == solution.unknownCount {
            return "Alt er beregnet (\(solution.solvedCount) værdier)"
        }
        return "\(solution.solvedCount) af \(solution.unknownCount) ukendte værdier er beregnet"
    }

    private var summaryColor: Color {
        if !solution.isConsistent { return .red }
        return solution.solvedCount == solution.unknownCount ? .green : .orange
    }

    private func symbol(for kind: SolverIssue.Kind) -> String {
        switch kind {
        case .conflict: "exclamationmark.octagon.fill"
        case .missing: "questionmark.circle.fill"
        case .notice: "info.circle.fill"
        }
    }

    private func color(for kind: SolverIssue.Kind) -> Color {
        switch kind {
        case .conflict: .red
        case .missing: .orange
        case .notice: .blue
        }
    }
}

extension CircuitSolution {
    /// Symbol for the toolbar button and report summary.
    static func symbol(for solution: CircuitSolution) -> String {
        if !solution.isConsistent { return "exclamationmark.triangle" }
        if solution.issues.contains(where: { $0.kind != .notice }) || solution.solvedCount < solution.unknownCount {
            return "questionmark.circle"
        }
        return solution.issues.isEmpty ? "checkmark.circle" : "info.circle"
    }
}

#Preview {
    var circuit = Circuit()
    circuit.components = [
        CircuitComponent(kind: .voltageSource, start: GridPoint(x: 0, y: 4), end: GridPoint(x: 0, y: 0), name: "V1", value: 12),
        CircuitComponent(kind: .resistor, start: GridPoint(x: 0, y: 0), end: GridPoint(x: 4, y: 0), name: "R1", value: nil),
        CircuitComponent(kind: .resistor, start: GridPoint(x: 4, y: 0), end: GridPoint(x: 4, y: 4), name: "R2", value: 50),
    ]
    circuit.wires = [Wire(points: [GridPoint(x: 4, y: 4), GridPoint(x: 0, y: 4)])]
    circuit.grounds = [Ground(position: GridPoint(x: 0, y: 4))]
    circuit.probes = [Probe(position: GridPoint(x: 4, y: 0), name: "VA")]
    return SolverReportView(solution: CircuitSolver.solve(circuit))
}
