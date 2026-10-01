#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// MARK: - Output

/// One line of a walkthrough: an explanation or a formula (LaTeX, drawn with `MathRowView`).
nonisolated enum WalkLine: Hashable {
    case text(String)
    case math(String)
}

/// A step of a walkthrough with a heading.
nonisolated struct WalkSection: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var lines: [WalkLine]
}

/// The methods a walkthrough can use.
nonisolated enum WalkMethod: String, CaseIterable, Identifiable {
    case nodal
    case mesh
    case superposition

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nodal: "Knudepunkt"
        case .mesh: "Maske"
        case .superposition: "Superposition"
        }
    }
}

nonisolated enum WalkResult {
    /// The steps, and the same method written as Maple code where the
    /// walkthrough makes it (the node-voltage method has its own exporter).
    case steps([WalkSection], maple: String? = nil)
    /// The method can't be used on this circuit, and why.
    case unavailable(String)
}

// MARK: - Formatting

nonisolated enum WalkFormat {
    /// A number with four significant digits, a decimal comma and a power of
    /// ten for very large or small numbers.
    static func number(_ value: Double) -> String {
        let value = abs(value) < 1e-12 ? 0 : value
        /// Four significant digits without trailing zeros: 12000, 0,0025, 1,667.
        func digits(_ x: Double) -> String {
            guard x != 0 else { return "0" }
            let decimals = max(0, 3 - Int(floor(log10(abs(x)))))
            var text = String(format: "%.\(decimals)f", x)
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return text.replacingOccurrences(of: ".", with: ",")
        }
        let magnitude = abs(value)
        if magnitude != 0, magnitude >= 1e5 || magnitude < 1e-3 {
            let exponent = Int(floor(log10(magnitude)))
            return "\(digits(value / pow(10, Double(exponent)))) \\cdot 10^{\(exponent)}"
        }
        return digits(value)
    }

    /// A number in brackets when it's negative, for putting into a formula.
    static func factor(_ value: Double) -> String {
        value < 0 ? "(\(number(value)))" : number(value)
    }

    /// A value with unit and SI prefix, e.g. "4 [[mA]]".
    static func quantity(_ value: Double, _ unit: PhysicalUnit) -> String {
        MathEvaluator.latex(for: Quantity(abs(value) < 1e-12 ? 0 : value, unit: unit))
    }

    /// A value with unit, in brackets when it's negative: "(-9 [[V]])".
    static func quantityFactor(_ value: Double, _ unit: PhysicalUnit) -> String {
        value < -1e-12 ? "(\(quantity(value, unit)))" : quantity(value, unit)
    }

    /// A, B, …, Z, then A1, B1, … for naming nodes and meshes.
    static var letters: [String] {
        let alphabet = (UnicodeScalar("A").value...UnicodeScalar("Z").value).compactMap { UnicodeScalar($0).map(String.init) }
        return (0..<10).flatMap { round in alphabet.map { $0 + (round == 0 ? "" : String(round)) } }
    }

    /// A name written as LaTeX with its subscript: R1 → R_{1}, VA → V_{A}.
    static func name(_ name: String) -> String {
        guard !name.contains("_"), name.count > 1 else { return name }
        return "\(name.prefix(1))_{\(name.dropFirst())}"
    }

    /// A LaTeX name for use in plain text: V_{A} → VA, i_{1} → i1.
    static func plain(_ latex: String) -> String {
        latex.filter { !"_{}".contains($0) }
    }

    /// Terms like "2 x - y + 3", in the order of `order`.
    static func combination(_ terms: [String: Double], constant: Double = 0, order: [String]) -> String {
        var parts: [(negative: Bool, body: String)] = []
        for variable in order {
            guard let coefficient = terms[variable], abs(coefficient) > 1e-12 else { continue }
            let body = abs(abs(coefficient) - 1) < 1e-12 ? variable : "\(number(abs(coefficient))) \(variable)"
            parts.append((coefficient < 0, body))
        }
        if abs(constant) > 1e-12 || parts.isEmpty {
            parts.append((constant < 0, number(abs(constant))))
        }
        return parts.enumerated().map { index, part in
            index == 0 ? (part.negative ? "-" : "") + part.body : (part.negative ? " - " : " + ") + part.body
        }.joined()
    }
}

// MARK: - Linear equations and gradual substitution

/// Σ coefficient · variable = constant, with variables named by their LaTeX.
nonisolated struct LinearEquation {
    var terms: [String: Double] = [:]
    var constant: Double = 0

    mutating func add(_ variable: String, _ coefficient: Double) {
        terms[variable, default: 0] += coefficient
    }

    func latex(order: [String]) -> String {
        "\(WalkFormat.combination(terms, order: order)) = \(WalkFormat.number(constant))"
    }
}

nonisolated enum Substitution {
    /// Solves the equations one unknown at a time, as by hand: isolate an
    /// unknown in the simplest equation, put it into the others, and finally
    /// work back through the isolated unknowns. `nil` if there's no single
    /// solution.
    static func solve(
        _ equations: [(label: String, equation: LinearEquation)], unknowns: [String]
    ) -> (lines: [WalkLine], values: [String: Double])? {
        let epsilon = 1e-12
        var remaining = equations
        var isolated: [(variable: String, terms: [String: Double], constant: Double)] = []
        var lines: [WalkLine] = []

        var unsolved = unknowns
        while !unsolved.isEmpty {
            // The equation with the fewest unknowns, so values that can be read
            // off directly come first and are put in right away.
            func count(_ index: Int) -> Int { remaining[index].equation.terms.values.filter { abs($0) > epsilon }.count }
            let usable = remaining.indices.filter { index in unsolved.contains { abs(remaining[index].equation.terms[$0] ?? 0) > epsilon } }
            guard let pick = usable.min(by: { count($0) < count($1) }),
                  let variable = unsolved.first(where: { abs(remaining[pick].equation.terms[$0] ?? 0) > epsilon })
            else { return nil }
            unsolved.removeAll { $0 == variable }
            let (label, equation) = remaining.remove(at: pick)
            let a = equation.terms[variable] ?? 1
            var terms: [String: Double] = [:]
            for (other, coefficient) in equation.terms where other != variable && abs(coefficient) > epsilon {
                terms[other] = -coefficient / a
            }
            let constant = equation.constant / a
            let plain = WalkFormat.plain(variable)
            lines.append(.text(terms.isEmpty ? "Af (\(label)) fås \(plain) direkte:" : "Isolér \(plain) i (\(label)):"))
            lines.append(.math("\(variable) = \(WalkFormat.combination(terms, constant: constant, order: unknowns))"))

            for index in remaining.indices {
                let c = remaining[index].equation.terms[variable] ?? 0
                guard abs(c) > epsilon else { continue }
                remaining[index].equation.terms[variable] = nil
                for (other, k) in terms { remaining[index].equation.add(other, c * k) }
                remaining[index].equation.constant -= c * constant
                remaining[index].equation.terms = remaining[index].equation.terms.filter { abs($0.value) > epsilon }
                lines.append(.text("Indsæt i (\(remaining[index].label)):"))
                lines.append(.math(remaining[index].equation.latex(order: unknowns)))
            }
            isolated.append((variable, terms, constant))
        }

        // Back through the isolated unknowns, last first.
        var values: [String: Double] = [:]
        var back: [WalkLine] = []
        for (variable, terms, constant) in isolated.reversed() {
            var value = constant
            var inserted: [String] = []
            for other in unknowns where terms[other] != nil {
                let k = terms[other] ?? 0
                let known = values[other] ?? 0
                value += k * known
                inserted.append("\(k < 0 ? "-" : "+") \(WalkFormat.number(abs(k))) \\cdot \(WalkFormat.factor(known))")
            }
            values[variable] = value
            if inserted.isEmpty {
                back.append(.math("\(variable) = \(WalkFormat.number(value))"))
            } else {
                let start = abs(constant) > epsilon ? WalkFormat.number(constant) + " " : ""
                var expression = start + inserted.joined(separator: " ")
                if start.isEmpty, expression.hasPrefix("+ ") { expression.removeFirst(2) }
                back.append(.math("\(variable) = \(expression) = \(WalkFormat.number(value))"))
            }
        }
        if isolated.count > 1 {
            lines.append(.text("Tilbage gennem de isolerede størrelser:"))
        }
        lines += back
        return (lines, values)
    }
}

// MARK: - The circuit as the walkthrough sees it

/// What a walkthrough works out: the voltage points and currents without a value.
nonisolated enum WalkTarget {
    case probe(Probe)
    case arrow(CurrentArrow)

    var name: String {
        switch self {
        case .probe(let probe): WalkFormat.name(probe.name)
        case .arrow(let arrow): WalkFormat.name(arrow.name)
        }
    }

    var unit: PhysicalUnit {
        if case .arrow = self { return .ampere }
        return .volt
    }

    var mapleName: String {
        switch self {
        case .probe(let probe): MapleExporter.name(probe.name)
        case .arrow(let arrow): MapleExporter.name(arrow.name)
        }
    }

    /// The Maple unit the result is converted to.
    var mapleUnit: String {
        if case .arrow = self { return "A" }
        return "V"
    }
}

/// A component with the nodes of its terminals.
nonisolated struct WalkPart {
    let component: CircuitComponent
    let start: Int
    let end: Int
    var symbol: String { WalkFormat.name(component.name) }
    /// The Maple name of its value; a controlled source's gain is beta__Ia.
    var mapleName: String { MapleExporter.valueName(of: component) }
    var value: Double { component.value ?? 0 }
    var kind: ComponentKind { component.kind }

    /// The symbol of its value: the name, or a controlled source's gain
    /// with the source's name lowered: \beta_{Ia}, \mu_{S2}.
    var valueSymbol: String {
        let gain = switch kind {
        case .vcvs: "\\mu"
        case .ccvs: "r"
        case .vccs: "g"
        case .cccs: "\\beta"
        default: ""
        }
        return gain.isEmpty ? symbol : "\(gain)_{\(component.name)}"
    }

    /// Voltage and current sources that aren't controlled, the ones
    /// superposition switches off.
    var isIndependent: Bool { kind == .voltageSource || kind == .currentSource }
}

/// What a controlled source depends on: the voltage between two nodes (Vs)
/// or the current where its Is point sits.
nonisolated struct WalkControl {
    enum Kind {
        case voltage(plus: Int, minus: Int)
        /// The current as components' currents (start → end) times these.
        case current(coefficients: [UUID: Double])
    }

    let kind: Kind
    /// The name in formulas, V_{s} or I_{x}; a controlling current is an
    /// unknown of its own under this name.
    let latex: String
    let maple: String
    var plain: String { WalkFormat.plain(latex) }
}

/// The circuit prepared for a walkthrough: supported parts, nodes and names.
nonisolated struct WalkModel {
    let circuit: Circuit
    let netlist: Netlist
    let parts: [WalkPart]
    /// The 0 V node, and whether it's where the ground symbol is.
    let reference: Int
    let referenceIsGround: Bool
    /// The other nodes with components, in order.
    let nodes: [Int]
    let nodeName: [Int: String]
    let targets: [WalkTarget]
    /// What each controlled source depends on, by source id.
    let controls: [UUID: WalkControl]

    /// The independent sources.
    var sources: [WalkPart] { parts.filter(\.isIndependent) }

    /// The name of a node's voltage in formulas; 0 for the reference.
    func voltageName(_ node: Int) -> String { node == reference ? "0" : nodeName[node] ?? "0" }

    /// Checks that the circuit is one the walkthroughs can explain.
    static func make(_ circuit: Circuit) -> Result<WalkModel, WalkError> {
        let netlist = Netlist(circuit)
        guard !circuit.components.isEmpty else { return .failure(.message("Kredsløbet har ingen komponenter endnu.")) }
        if let unknown = circuit.components.first(where: { $0.value == nil }) {
            return .failure(.message("\(unknown.name) har ingen værdi. Gennemgangen viser indtil videre kun, hvordan manglende spændinger og strømme findes, når alle komponenter er kendt."))
        }
        if let short = circuit.components.first(where: { $0.kind == .resistor && ($0.value ?? 0) <= 0 }) {
            return .failure(.message("\(short.name) er 0 Ω. Erstat den med en ledning."))
        }
        var parts: [WalkPart] = []
        for component in circuit.components {
            guard let start = netlist.nodeOf[component.start], let end = netlist.nodeOf[component.end] else { continue }
            parts.append(WalkPart(component: component, start: start, end: end))
        }
        guard parts.contains(where: { $0.component.kind != .resistor }) else {
            return .failure(.message("Kredsløbet har ingen kilder, så alle spændinger og strømme er 0."))
        }

        let partNodes = Set(parts.flatMap { [$0.start, $0.end] })
        let reference: Int
        let referenceIsGround: Bool
        if let ground = netlist.groundNode, partNodes.contains(ground) {
            reference = ground
            referenceIsGround = true
        } else {
            // The node with the most terminals.
            let counts = Dictionary(parts.flatMap { [$0.start, $0.end] }.map { ($0, 1) }, uniquingKeysWith: +)
            reference = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 0
            referenceIsGround = false
        }

        // Nodes in reading order (top left first), named after a voltage point
        // on them, otherwise V_{A}, V_{B}, … with letters no other name uses.
        var topLeft: [Int: GridPoint] = [:]
        for (point, node) in netlist.nodeOf where topLeft[node].map({ (point.y, point.x) < ($0.y, $0.x) }) ?? true {
            topLeft[node] = point
        }
        let nodes = partNodes.subtracting([reference]).sorted { a, b in
            let p = topLeft[a] ?? GridPoint(x: 0, y: 0), q = topLeft[b] ?? GridPoint(x: 0, y: 0)
            return (p.y, p.x) < (q.y, q.x)
        }
        var nodeName: [Int: String] = [:]
        // Only voltage points named like a node (VA, VB, …) name their node;
        // others, like Vo, are written from the node's letter: V_o = V_B - 0.
        for probe in circuit.probes where !probe.isVoltageDrop {
            let key = FormulaParts.key(probe.name)
            guard key.count > 1, key.first == "V", key.dropFirst().allSatisfy({ $0.isUppercase || $0.isNumber }) else { continue }
            if let node = netlist.nodeOf[probe.position], node != reference, nodeName[node] == nil {
                nodeName[node] = WalkFormat.name(probe.name)
            }
        }
        var taken = Set((circuit.components.map(\.name) + circuit.probes.map(\.name) + circuit.currents.map(\.name)).map(FormulaParts.key))
        taken.formUnion(nodeName.values.map(FormulaParts.key))
        var letters = WalkFormat.letters.makeIterator()
        for node in nodes where nodeName[node] == nil {
            while let letter = letters.next() {
                guard !taken.contains("V" + letter) else { continue }
                nodeName[node] = "V_{\(letter)}"
                break
            }
        }

        var targets: [WalkTarget] = circuit.probes.filter { $0.value == nil }.map { .probe($0) }
            + circuit.currents.filter { $0.value == nil }.map { .arrow($0) }
        if targets.isEmpty {
            targets = circuit.probes.map { .probe($0) } + circuit.currents.map { .arrow($0) }
        }
        guard !targets.isEmpty else {
            return .failure(.message("Sæt et spændingspunkt eller en strømpil uden værdi dér, hvor du vil have gennemgangen til at regne."))
        }

        // What the controlled sources depend on.
        var controls: [UUID: WalkControl] = [:]
        let dependent = parts.filter { $0.kind.isDependent }
        for part in dependent {
            let component = part.component
            let sameKind = dependent.filter { $0.kind.isVoltageControlled == part.kind.isVoltageControlled }.count
            let letter = part.kind.isVoltageControlled ? "V" : "I"
            let latex = component.controlName.map(WalkFormat.name)
                ?? (sameKind == 1 ? "\(letter)_{s}" : "\(letter)_{s,\(component.name)}")
            let maple = component.controlName.map { MapleExporter.name($0) }
                ?? (sameKind == 1 ? "\(letter)s" : "\(letter)s__\(MapleExporter.name(component.name))")
            if part.kind.isVoltageControlled {
                guard let plus = circuit.sense(of: component.id, .plus).flatMap({ netlist.nodeOf[$0.gridPoint] }),
                      let minus = circuit.sense(of: component.id, .minus).flatMap({ netlist.nodeOf[$0.gridPoint] }) else {
                    return .failure(.message("Træk + og − punkterne for \(component.name) hen på kredsløbet, der hvor \(component.controlLabel) skal måles."))
                }
                controls[component.id] = WalkControl(kind: .voltage(plus: plus, minus: minus), latex: latex, maple: maple)
            } else {
                guard let arrow = circuit.sense(of: component.id, .current).flatMap({ circuit.currentArrow(for: $0) }) else {
                    return .failure(.message("Træk \(component.controlLabel)-punktet for \(component.name) hen på den ledning, hvor den styrende strøm løber."))
                }
                // The current from the side of the wire without voltage sources,
                // whose currents the node voltages don't give.
                let sides = [false, true].compactMap { netlist.componentCoefficients(for: arrow, in: circuit, fromOtherSide: $0) }
                func throughVoltageSource(_ coefficients: [UUID: Double]) -> Bool {
                    parts.contains { $0.kind.setsVoltage && abs(coefficients[$0.component.id] ?? 0) > 1e-9 }
                }
                guard let coefficients = sides.first(where: { !throughVoltageSource($0) }) ?? sides.first else {
                    return .failure(.message("\(component.controlLabel) for \(component.name) kan ikke findes, fordi ledningen er en del af en løkke af ledninger. Flyt \(component.controlLabel)-punktet."))
                }
                controls[component.id] = WalkControl(kind: .current(coefficients: coefficients), latex: latex, maple: maple)
            }
        }

        return .success(WalkModel(
            circuit: circuit, netlist: netlist, parts: parts, reference: reference,
            referenceIsGround: referenceIsGround, nodes: nodes, nodeName: nodeName, targets: targets,
            controls: controls
        ))
    }

    /// "R_{1} = 1 [[kΩ]]" for each component, with what the sources are.
    func knownValueLines(_ parts: [WalkPart]? = nil) -> [WalkLine] {
        let parts = parts ?? self.parts
        var lines: [WalkLine] = [.text("Kendte værdier:")]
        lines += parts.map { part in
            let unit = PhysicalUnit(symbol: part.kind.displayUnit) ?? .none
            // Gains without a unit are written as plain numbers.
            let value = unit == .none ? WalkFormat.number(part.value) : WalkFormat.quantity(part.value, unit)
            return .math("\(part.valueSymbol) = \(value)")
        }
        let voltageSources = parts.filter { $0.component.kind == .voltageSource }.map(\.component.name)
        let currentSources = parts.filter { $0.component.kind == .currentSource }.map(\.component.name)
        if !voltageSources.isEmpty {
            lines.append(.text("Spændingskilder: \(voltageSources.joined(separator: ", ")) (med + og − som på symbolet)."))
        }
        if !currentSources.isEmpty {
            lines.append(.text("Strømkilder: \(currentSources.joined(separator: ", ")) (strømmen løber i pilens retning)."))
        }
        let dependent = parts.filter { $0.kind.isDependent }
        if !dependent.isEmpty {
            lines.append(.text("Styrede kilder – deres spænding eller strøm er faktoren gange det, de styres af:"))
            for part in dependent {
                guard let control = controls[part.component.id] else { continue }
                let output = part.kind.setsVoltage ? "V_{\(part.component.name)}" : "I_{\(part.component.name)}"
                lines.append(.math("\(output) = \(part.valueSymbol) \\cdot \(control.latex)"))
                switch control.kind {
                case .voltage(let plus, let minus):
                    lines.append(.math("\(control.latex) = \(voltageName(plus)) - \(voltageName(minus))"))
                case .current:
                    lines.append(.text("\(control.plain) er strømmen under \(control.plain)-punktet, i pilens retning."))
                }
            }
        }
        return lines
    }

    // MARK: Maple

    /// The start of a Maple script: units and the known values. Like the
    /// node-voltage export, everything but the results ends with `:`.
    func mapleHeader() -> [String] {
        var lines = ["with(Units):", "unassign(anames(user)):", "", "# Kendte værdier"]
        for part in parts {
            let value = switch part.kind {
            case .resistor, .ccvs: MapleExporter.quantity(part.value, base: "ohm")
            case .currentSource: MapleExporter.quantity(part.value, base: "A")
            case .voltageSource: MapleExporter.quantity(part.value, base: "V")
            case .vccs: "\(MapleExporter.number(part.value))*Unit('A'/'V')"
            default: MapleExporter.number(part.value)
            }
            lines.append("\(part.mapleName) := \(value):")
        }
        return lines
    }

    /// The only lines Maple prints: a target with its value in its unit.
    static func mapleResult(_ target: WalkTarget, _ expression: String, value: Double?) -> String {
        let digits = MapleExporter.significantDigits(for: value)
        let unit = MapleExporter.prefixed(value, base: target.mapleUnit).unit
        return "\(target.mapleName) := evalf(convert(\(expression), 'units', '\(unit)'), \(digits));"
    }
}

nonisolated enum WalkError: Error {
    case message(String)

    var text: String {
        switch self {
        case .message(let text): text
        }
    }
}

// MARK: - Making a walkthrough

nonisolated enum Walkthrough {
    static func make(_ method: WalkMethod, for circuit: Circuit) -> WalkResult {
        let diodes = circuit.components.filter { $0.kind.isDiode }
        guard !diodes.isEmpty else { return makeLinear(method, for: circuit) }
        if let unknown = diodes.first(where: { $0.value == nil }) {
            return .unavailable("\(unknown.name) har ingen tærskelspænding.")
        }

        // The cookbook for diode models: guess each diode ON or OFF, put its
        // model in its place, solve as usual, and check the guess. The guess
        // is the solver's, which already fits.
        let solution = CircuitSolver.solve(circuit)
        guard solution.isConsistent, diodes.allSatisfy({ solution.diodeValues[$0.id] != nil }) else {
            return .unavailable("Der er ingen kombination af ledende (ON) og spærrende (OFF) dioder, der passer med resten af kredsløbet.")
        }
        var linear = circuit
        var guess: [WalkLine] = [
            .text("1: For hver diode gættes ON eller OFF."),
            .text("2: Modellen sættes ind på diodens plads: ON er en spændingskilde V_K med + ved anoden (strømmen I_d), OFF er en afbrydelse (spændingen V_d)."),
        ]
        var check: [WalkLine] = [.text("4: Gættet kontrolleres: Id > 0 for ON og Vd < VK for OFF.")]
        for diode in diodes {
            let vk = diode.value ?? 0
            let values = solution.diodeValues[diode.id] ?? (0, 0)
            let name = WalkFormat.name(diode.name)
            linear.components.removeAll { $0.id == diode.id }
            if solution.diodeConducts[diode.id] == true {
                // + at the anode (start); a voltage source has + at its end.
                linear.components.append(CircuitComponent(
                    id: diode.id, kind: .voltageSource, start: diode.end, end: diode.start, name: diode.name, value: vk
                ))
                guess.append(.math("\(name):\\; \\text{ON} \\Rightarrow V_{d} = V_{K} = \(WalkFormat.quantity(vk, .volt))"))
                check.append(.math("I_{\(diode.name)} = \(WalkFormat.quantity(values.current, .ampere)) > 0 \\;\\checkmark"))
            } else {
                guess.append(.math("\(name):\\; \\text{OFF} \\Rightarrow I_{d} = 0"))
                check.append(.math("V_{\(diode.name)} = \(WalkFormat.quantity(values.voltage, .volt)) < V_{K} = \(WalkFormat.quantity(vk, .volt)) \\;\\checkmark"))
            }
        }
        guess.append(.text("3: Kredsløbet regnes som normalt med modellerne indsat:"))
        check.append(.text("5: Alle betingelser er opfyldt, så gættet holder (ellers OMMER med et nyt gæt)."))

        switch makeLinear(method, for: linear) {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .steps(let sections, let maple):
            return .steps(
                [WalkSection(title: "Diodemodeller", lines: guess)] + sections
                    + [WalkSection(title: "Kontrol af dioderne", lines: check)],
                maple: maple
            )
        }
    }

    /// A walkthrough of a circuit of linear components only.
    private static func makeLinear(_ method: WalkMethod, for circuit: Circuit) -> WalkResult {
        switch WalkModel.make(circuit) {
        case .failure(let error):
            return .unavailable(error.text)
        case .success(let model):
            switch method {
            case .nodal: return NodalWalkthrough.make(model)
            case .mesh: return MeshWalkthrough.make(model)
            case .superposition: return SuperpositionWalkthrough.make(model)
            }
        }
    }
}
