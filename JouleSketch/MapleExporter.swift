import Foundation

/// Writes the circuit as Maple code using the node voltage method
/// (knudepunktsmetoden), ready to paste into a Maple worksheet.
///
/// Everything up to the results ends with `:` so Maple doesn't print it;
/// only the result lines end with `;`. Known values are assigned with units, node equations (Kirchhoff's current
/// law, currents leaving the node) are written with names so they work as
/// documentation in an assignment, and the unknowns are solved for. Only
/// the ones the user asked for are converted to sensible units and shown:
///
/// ```
/// with(Units):
/// unassign(anames(user)):
/// R1 := 50*Unit('ohm'):
/// S1 := 12*Unit('V'):
/// VA := S1:
/// L1 := (VA - VB)/R2 - I1 = 0:
/// sol := solve({L1, L2}, {R2, VB}):
/// assign(sol):
/// VB := evalf(convert(VB, 'units', 'V'), 4);
/// ```
///
/// No square brackets (`res[1]`, `evalf[4]`), so the code can also be
/// copied as MathML (`MapleMathML`), where brackets would read as subscripts:
///
/// ```
/// ```
nonisolated enum MapleExporter {
    static func export(_ circuit: Circuit) -> String {
        let (circuit, lowSide) = CircuitSolver.resolvingLowSideOutputs(circuit.resolvingSwitches().resolvingZeroFrequencyGenerators())
        if !lowSide.isEmpty {
            let notes = lowSide.map { "# \($0.name) er en low-side udgang (LSO): et firkantsignal fra 0 V til \($0.openVoltage.map { SIValue.format($0, unit: "V") } ?? "?") (spændingen over den, når den er åben)" }
            return (notes + [export(circuit)]).joined(separator: "\n")
        }
        if circuit.usesFourier {
            // Two scripts: the averages, then the fundamental with phasors.
            let average = circuit.averageCircuit()
            let solution = CircuitSolver.solve(average)
            let (split, notes) = splittingLEDs(average)
            var writer = Writer(circuit: split)
            var fundamental = Writer(circuit: circuit.fundamentalCircuit(componentValues: solution.componentValues))
            let lines: [String] = ["# Del 1: middelværdier (signalets middelværdi, kondensatorer afbrudt, spoler kortsluttet)"] + notes
                + [writer.build(), "", "# Del 2: grundtonen (signalets første Fourier-led), andre kilder slukket", fundamental.build()]
            return lines.joined(separator: "\n")
        }
        let (split, notes) = splittingLEDs(circuit)
        var writer = Writer(circuit: split)
        return (notes + [writer.build()]).joined(separator: "\n")
    }

    /// In DC each conducting LED as its model, a source V_K in series with its
    /// internal resistance, and a note for each.
    private static func splittingLEDs(_ circuit: Circuit) -> (Circuit, [String]) {
        guard !circuit.isAC, circuit.components.contains(where: { $0.kind == .led }) else { return (circuit, []) }
        let solution = CircuitSolver.solve(circuit)
        let conducting = Set(circuit.components.filter { $0.kind == .led && solution.diodeConducts[$0.id] == true }.map(\.id))
        let (split, resistors) = circuit.splittingLEDs(conducting: conducting)
        let notes = circuit.components.compactMap { led in
            resistors[led.id].map { "# \(led.name) leder og regnes som spændingskilden \(name(led.name)) (V_K) i serie med sin indre modstand \(name($0.name)) = \(SIValue.format($0.value, unit: "Ω"))" }
        }
        return (split, notes)
    }

    /// A user-entered or LaTeX name as a valid Maple name: V_{A} → V_A.
    static func name(_ name: String) -> String { Writer.mapleName(name) }

    /// A number in a form Maple reads.
    static func number(_ value: Double) -> String { Writer.number(value) }

    /// The Maple name of a component's value: R1, or a controlled source's
    /// gain such as beta__Ia.
    static func valueName(of component: CircuitComponent) -> String { Writer.valueName(of: component) }

    /// Significant digits for `evalf(x, n)`.
    static func significantDigits(for value: Double?) -> Int { Writer.significantDigits(for: value) }

    /// Maple units with SI prefixes, largest first, for "V", "A", "ohm",
    /// "F", "H" and "Hz".
    /// Maple writes Ω and µ inside names as `&Omega;` and `&mu;`, so the
    /// backquoted name `k&Omega;` is kΩ.
    private static let prefixedUnits: [String: [(factor: Double, unit: String)]] = [
        "V": [(1e3, "kV"), (1, "V"), (1e-3, "mV"), (1e-6, "`&mu;V`")],
        "A": [(1, "A"), (1e-3, "mA"), (1e-6, "`&mu;A`"), (1e-9, "nA")],
        "ohm": [(1e6, "`M&Omega;`"), (1e3, "`k&Omega;`"), (1, "`&Omega;`")],
        "F": [(1, "F"), (1e-3, "mF"), (1e-6, "`&mu;F`"), (1e-9, "nF"), (1e-12, "pF")],
        "H": [(1, "H"), (1e-3, "mH"), (1e-6, "`&mu;H`")],
        "Hz": [(1e6, "MHz"), (1e3, "kHz"), (1, "Hz")],
    ]

    /// The unit with the prefix that suits a value, and the value in it:
    /// 4000 Ω → (4, "`k&Omega;`"), 0.002 A → (2, "mA"). Unknown and zero
    /// values keep the plain unit.
    static func prefixed(_ value: Double?, base: String) -> (value: Double?, unit: String) {
        guard let units = prefixedUnits[base] else { return (value, base) }
        guard let value, value != 0, value.isFinite else { return (value, units.first { $0.factor == 1 }?.unit ?? base) }
        let choice = units.first { abs(value) >= $0.factor * 0.999_999 } ?? units[units.count - 1]
        return (value / choice.factor, choice.unit)
    }

    /// A known value with its unit: "4*Unit('`k&Omega;`')".
    static func quantity(_ value: Double, base: String) -> String {
        let (scaled, unit) = prefixed(value, base: base)
        return "\(number(scaled ?? value))*Unit('\(unit)')"
    }
}

nonisolated private struct Writer {
    /// What kind of quantity a Maple name holds, for its unit and the final listing.
    enum Quantity: Int, Comparable {
        case voltage, resistance, capacitance, inductance, sourceVoltage, sourceCurrent, current
        /// Gains of controlled sources: μ (V/V), r (V/A), g (A/V) and β (A/A).
        case voltageGain, transresistance, transconductance, currentGain
        case frequency

        /// The unit, before an SI prefix is chosen (`MapleExporter.prefixed`),
        /// or `nil` for gains without one.
        var baseUnit: String? {
            switch self {
            case .voltage, .sourceVoltage: "V"
            case .resistance, .transresistance: "ohm"
            case .capacitance: "F"
            case .inductance: "H"
            case .frequency: "Hz"
            case .sourceCurrent, .current: "A"
            case .transconductance, .voltageGain, .currentGain: nil
            }
        }

        static func < (lhs: Quantity, rhs: Quantity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let circuit: Circuit
    let netlist: Netlist
    /// Maple name of each node's voltage; the ground node is written as 0.
    var nodeNames: [Int: String] = [:]
    var usedNames = Set<String>()
    /// Every Maple name in the output and what it holds.
    var quantities: [String: Quantity] = [:]
    /// Names that get a value before solving (known values and definitions).
    var assigned = Set<String>()
    /// For voltage sources whose current is measured by a current arrow:
    /// the arrow's name and the sign relating the two.
    var sourceCurrentArrows: [UUID: (name: String, sign: Double)] = [:]
    /// Names of the controlling quantities (Vs, Is) of controlled sources.
    var controlNames: [UUID: String] = [:]
    var lines: [String] = []
    /// The app's own solution, which also tells which diodes conduct.
    let solution: CircuitSolution
    /// The Maple name of the angular frequency ω in AC, `nil` in DC.
    var omegaName: String?

    init(circuit: Circuit) {
        self.circuit = circuit
        self.netlist = Netlist(circuit)
        self.solution = CircuitSolver.solve(circuit)
    }

    // MARK: Diodes

    /// Whether a component sets the voltage across it: a voltage source, a
    /// conducting diode (its forward voltage), or an inductor in DC (0 V).
    /// A blocking diode carries no current.
    private func setsVoltage(_ component: CircuitComponent) -> Bool {
        component.kind.setsVoltage || (component.kind.isDiode && conducts(component))
            || (component.kind == .inductor && omegaName == nil)
    }

    private func conducts(_ component: CircuitComponent) -> Bool {
        solution.diodeConducts[component.id] == true
    }

    /// The terminal at the higher voltage: + of a source, the anode of a diode.
    private func plusPoint(_ component: CircuitComponent) -> GridPoint {
        component.kind.isDiode ? component.start : component.end
    }

    private func minusPoint(_ component: CircuitComponent) -> GridPoint {
        component.kind.isDiode ? component.end : component.start
    }

    // MARK: Names

    /// Names Maple reserves or the output uses, which can't be used as variables.
    private static let reserved: Set<String> = [
        "I", "D", "O", "Pi", "gamma", "Catalan", "infinity", "true", "false", "FAIL",
        "and", "or", "not", "if", "then", "else", "fi", "do", "od", "for", "from", "to", "by",
        "while", "in", "end", "proc", "local", "global", "option", "options", "sum", "sol", "res",
        "Unit", "Units", "Omega", "ohm", "V", "A", "convert", "units",
    ]

    /// Turns a user-entered name into a valid Maple name.
    static func mapleName(_ name: String) -> String {
        // A subscript becomes Maple's "__", which Maple shows lowered:
        // V_{A}, V_A and V__A all become V__A.
        var subscripted = ""
        var underscore = false
        for character in name where character != "{" && character != "}" {
            if character == "_" {
                underscore = true
                continue
            }
            if underscore { subscripted += "__" }
            underscore = false
            subscripted.append(character)
        }
        if underscore { subscripted += "_" }
        // Maple reads a lowered I as the imaginary unit with an index when the
        // code is pasted as 2-D Math, so currents like I__S1 use a small i.
        if subscripted.hasPrefix("I__") { subscripted = "i" + subscripted.dropFirst() }
        // Danish letters first, then any other accents, then anything else becomes "_".
        let danish = subscripted
            .replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "ø", with: "oe")
            .replacingOccurrences(of: "å", with: "aa").replacingOccurrences(of: "Æ", with: "AE")
            .replacingOccurrences(of: "Ø", with: "OE").replacingOccurrences(of: "Å", with: "AA")
        let ascii = danish.applyingTransform(.stripDiacritics, reverse: false) ?? danish
        var result = ascii.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" ? String($0) : "_" }.joined()
        if result.isEmpty { result = "x" }
        if let first = result.first, first.isNumber { result = "_" + result }
        if reserved.contains(result) || isEquationName(result) { result += "_" }
        return result
    }

    /// `L1`, `L2`, … are used for the equations.
    private static func isEquationName(_ name: String) -> Bool {
        name.hasPrefix("L") && name.count > 1 && name.dropFirst().allSatisfy(\.isNumber)
    }

    private mutating func uniqueName(_ base: String) -> String {
        var name = base
        var counter = 2
        while usedNames.contains(name) {
            name = "\(base)_\(counter)"
            counter += 1
        }
        usedNames.insert(name)
        return name
    }

    private func name(of component: CircuitComponent) -> String { Writer.valueName(of: component) }

    /// The Maple name of a component's value. A controlled source's value is
    /// its gain, named by the gain's symbol with the source's name lowered:
    /// beta__Ia (shown by Maple as β with Ia lowered), mu__S2, r__S3, g__S4.
    static func valueName(of component: CircuitComponent) -> String {
        let plain = Writer.mapleName(component.name)
        guard component.kind.isDependent else { return plain }
        let symbol = switch component.kind {
        case .vcvs: "mu"
        case .cccs: "beta"
        default: component.kind.gainSymbol
        }
        return "\(symbol)__\(plain.drop { $0 == "_" })"
    }

    /// Maple name for the unknown current through a voltage source: i__S1
    /// (a lowered capital I would be the imaginary unit in 2-D Math).
    private func sourceCurrentName(_ component: CircuitComponent) -> String {
        "i__" + Writer.mapleName(component.name).drop { $0 == "_" }
    }

    // MARK: Expressions

    private func voltage(at point: GridPoint) -> String {
        guard let node = netlist.nodeOf[point], node != netlist.groundNode else { return "0" }
        return nodeNames[node] ?? "0"
    }

    /// Whether a node's voltage has a value before solving.
    private func isKnown(_ node: Int?) -> Bool {
        guard let node else { return false }
        if node == netlist.groundNode { return true }
        return nodeNames[node].map { assigned.contains($0) } ?? false
    }

    /// The 0 V an inductor sets in DC.
    private static let zeroVolts = "0*Unit('V')"

    /// `a − b` or `a + b`, leaving out a zero `a`.
    private func combine(_ a: String, _ sign: String, _ b: String) -> String {
        if b == Writer.zeroVolts { return a == "0" ? b : a }
        if a == "0" { return sign == "+" ? b : "-\(b)" }
        return "\(a) \(sign) \(b)"
    }

    /// The current through a voltage source from its − to its + terminal.
    private func sourceCurrent(_ component: CircuitComponent) -> (sign: Double, term: String) {
        if let arrow = sourceCurrentArrows[component.id] { return (arrow.sign, arrow.name) }
        return (1, sourceCurrentName(component))
    }

    /// The Maple name of a controlled source's controlling quantity: `Vs` or
    /// `Is` (`Vs_S2`, `Is_S3` … when there are several). `nil` if its sense
    /// markers aren't placed on the circuit.
    private func control(of component: CircuitComponent) -> String? {
        controlNames[component.id]
    }

    /// What a source sets: `S1` for an independent source, `S3*(VA - VB)`
    /// (gain times control) for a controlled one, and `S1*exp(30*I*Pi/180)`
    /// for a signal generator with a phase.
    private func sourceValue(_ component: CircuitComponent) -> String {
        if component.kind == .inductor { return Writer.zeroVolts }
        if component.kind == .signalGenerator, let phase = Writer.phaseFactor(component) {
            return "\(name(of: component))*\(phase)"
        }
        guard component.kind.isDependent, let control = control(of: component) else { return name(of: component) }
        return "\(name(of: component))*\(control)"
    }

    /// A signal generator's phase as `exp(30*I*Pi/180)`, `nil` for 0°.
    static func phaseFactor(_ component: CircuitComponent) -> String? {
        guard let phase = component.phase, phase != 0 else { return nil }
        return "exp(\(number(phase))*I*Pi/180)"
    }

    /// The current through a resistor, capacitor or inductor from a voltage
    /// across it: `(VA - VB)/R1`, `(VA - VB)*I*omega*C1`, `(VA - VB)/(I*omega*L1)`.
    private func passiveCurrent(_ component: CircuitComponent, across: String) -> String {
        let value = name(of: component)
        switch component.kind {
        case .capacitor:
            guard let omegaName else { return "0" }
            return "(\(across))*I*\(omegaName)*\(value)"
        case .inductor:
            guard let omegaName else { return "0" }
            return "(\(across))/(I*\(omegaName)*\(value))"
        default:
            return "(\(across))/\(value)"
        }
    }

    /// The current through a component, from its start to its end terminal.
    private func current(of component: CircuitComponent) -> (sign: Double, term: String) {
        switch component.kind {
        case .resistor, .capacitor, .inductor:
            // In DC a capacitor carries no current; an inductor is a short.
            if omegaName == nil, component.kind == .capacitor { return (1, "0") }
            if omegaName == nil, component.kind == .inductor { return sourceCurrent(component) }
            let from = voltage(at: component.start)
            let to = voltage(at: component.end)
            return (1, passiveCurrent(component, across: "\(from) - \(to)"))
        case .voltageSource, .signalGenerator, .vcvs, .ccvs:
            return sourceCurrent(component)
        case .currentSource, .vccs, .cccs:
            return (1, sourceValue(component))
        case .toggleSwitch, .pushButton:
            // Switches are resolved into wires before writing.
            return (1, "0")
        case .diode, .led:
            // A blocking diode carries no current.
            return conducts(component) ? sourceCurrent(component) : (1, "0")
        }
    }

    /// Joins signed terms into a sum like `a - b + c`.
    private func sum(_ terms: [(sign: Double, term: String)]) -> String {
        let nonZero = terms.filter { $0.term != "0" && $0.sign != 0 }
        guard !nonZero.isEmpty else { return "0" }
        var result = ""
        for (index, item) in nonZero.enumerated() {
            let negative = item.sign < 0
            if index == 0 {
                result = negative ? "-\(item.term)" : item.term
            } else {
                result += negative ? " - \(item.term)" : " + \(item.term)"
            }
        }
        return result
    }

    /// A number in a form Maple reads.
    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        let text = String(format: "%.10g", value)
        guard let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return text }
        let mantissa = text[..<e]
        let exponent = Int(text[text.index(after: e)...]) ?? 0
        return "\(mantissa)*10^(\(exponent))"
    }

    private mutating func assign(_ name: String, _ value: Double, as quantity: Quantity) {
        quantities[name] = quantity
        assigned.insert(name)
        let written = if let base = quantity.baseUnit {
            MapleExporter.quantity(value, base: base)
        } else if quantity == .transconductance {
            "\(Writer.number(value))*Unit('A'/'V')"
        } else {
            Writer.number(value)
        }
        lines.append("\(name) := \(written):")
    }

    // MARK: Output

    mutating func build() -> String {
        guard !circuit.components.isEmpty else {
            return "# JouleSketch: kredsløbet har ingen komponenter endnu."
        }

        // Reserve the names the user chose, so generated names don't clash.
        for component in circuit.components { usedNames.insert(name(of: component)) }
        for probe in circuit.probes { usedNames.insert(Writer.mapleName(probe.name)) }
        for arrow in circuit.currents { usedNames.insert(Writer.mapleName(arrow.name)) }
        // AC: phasors at the angular frequency ω = 2πf of the signal generators.
        var frequencyName: String?
        if circuit.isAC {
            frequencyName = uniqueName("f")
            omegaName = uniqueName("omega")
        }
        for component in circuit.components where setsVoltage(component) {
            usedNames.insert(sourceCurrentName(component))
        }

        // Node voltages take the name of a voltage point on the node, if any.
        var extraProbes: [(name: String, node: Int)] = []
        for probe in circuit.probes where !probe.isVoltageDrop {
            guard let node = netlist.nodeOf[probe.position] else { continue }
            let probeName = Writer.mapleName(probe.name)
            quantities[probeName] = .voltage
            if node == netlist.groundNode || nodeNames[node] != nil {
                extraProbes.append((probeName, node))
            } else {
                nodeNames[node] = probeName
            }
        }
        let nodesWithComponents = Set(circuit.components.flatMap { [netlist.nodeOf[$0.start], netlist.nodeOf[$0.end]] }.compactMap { $0 })
        for node in nodesWithComponents.sorted() where node != netlist.groundNode && nodeNames[node] == nil {
            let name = uniqueName("V__k\(node + 1)")
            nodeNames[node] = name
            quantities[name] = .voltage
        }

        // Controlled sources: Vs is the voltage between the + and − sense points,
        // Is the current under the Is marker (written as an extra equation).
        var controlDefinitions: [String] = []
        var controlCurrents: [(name: String, coefficients: [UUID: Double])] = []
        let voltageControlled = circuit.components.filter { $0.kind.isVoltageControlled }
        let currentControlled = circuit.components.filter { $0.kind.isCurrentControlled }
        for component in voltageControlled {
            guard let plus = circuit.sense(of: component.id, .plus),
                  let minus = circuit.sense(of: component.id, .minus),
                  netlist.nodeOf[plus.gridPoint] != nil, netlist.nodeOf[minus.gridPoint] != nil else { continue }
            let symbol = uniqueName(component.controlName == nil
                ? (voltageControlled.count == 1 ? "Vs" : "Vs__\(Writer.mapleName(component.name))")
                : Writer.mapleName(component.controlLabel))
            controlNames[component.id] = symbol
            quantities[symbol] = .voltage
            controlDefinitions.append("\(symbol) := \(combine(voltage(at: plus.gridPoint), "-", voltage(at: minus.gridPoint))):")
        }
        for component in currentControlled {
            guard let marker = circuit.sense(of: component.id, .current),
                  let arrow = circuit.currentArrow(for: marker),
                  let coefficients = netlist.componentCoefficients(for: arrow, in: circuit) else { continue }
            let symbol = uniqueName(component.controlName == nil
                ? (currentControlled.count == 1 ? "Is" : "Is__\(Writer.mapleName(component.name))")
                : Writer.mapleName(component.controlLabel))
            controlNames[component.id] = symbol
            quantities[symbol] = .current
            controlCurrents.append((symbol, coefficients))
        }

        // A current arrow measuring exactly a voltage source's current stands in
        // for the source's unknown current in the node equations.
            var arrowExpressions: [(name: String, coefficients: [UUID: Double])] = []
        for arrow in circuit.currents {
            let arrowName = Writer.mapleName(arrow.name)
            quantities[arrowName] = .current
            // Arrows on a loop of wires can't be written as an equation.
            guard let coefficients = netlist.componentCoefficients(for: arrow, in: circuit) else { continue }
            // The current can be written from either side of the arrow; prefer the
            // side where it's exactly one voltage source's current.
            let otherSide = netlist.componentCoefficients(for: arrow, in: circuit, fromOtherSide: true) ?? coefficients
            let sourceSide = [coefficients, otherSide].first { candidate in
                guard candidate.count == 1, let id = candidate.keys.first else { return false }
                return circuit.components.first { $0.id == id }.map(setsVoltage) == true && sourceCurrentArrows[id] == nil
            }
            if let sourceSide, let (id, coefficient) = sourceSide.first {
                // arrow = coefficient · i  ⇒  i = coefficient · arrow (coefficient is ±1)
                sourceCurrentArrows[id] = (arrowName, coefficient)
            } else {
                // Write it with the fewest components.
                arrowExpressions.append((arrowName, otherSide.count < coefficients.count ? otherSide : coefficients))
            }
        }
        for component in circuit.components {
            quantities[name(of: component)] = switch component.kind {
            case .resistor: .resistance
            case .voltageSource: .sourceVoltage
            case .currentSource: .sourceCurrent
            case .vcvs: .voltageGain
            case .ccvs: .transresistance
            case .vccs: .transconductance
            case .cccs: .currentGain
            case .diode, .led, .signalGenerator: .sourceVoltage
            case .capacitor: .capacitance
            case .inductor: .inductance
            case .toggleSwitch, .pushButton: .current
            }
            if setsVoltage(component), sourceCurrentArrows[component.id] == nil {
                quantities[sourceCurrentName(component)] = .current
            }
        }

        lines.append("with(Units):")
        lines.append("unassign(anames(user)):")
        lines.append("")

        // Known values, with units.
        lines.append("# Kendte værdier")
        for component in circuit.components {
            guard let value = component.value, let quantity = quantities[name(of: component)] else { continue }
            assign(name(of: component), value, as: quantity)
        }
        for probe in circuit.probes {
            if let value = probe.value { assign(Writer.mapleName(probe.name), value, as: .voltage) }
        }
        for arrow in circuit.currents {
            if let value = arrow.value { assign(Writer.mapleName(arrow.name), value, as: .current) }
        }
        if let frequencyName, let omegaName {
            lines.append("")
            lines.append("# Fasorer (AC) ved signalgeneratorens frekvens: Z_C = 1/(I*omega*C), Z_L = I*omega*L")
            if case .success(let frequency) = circuit.acFrequency() {
                assign(frequencyName, frequency, as: .frequency)
            }
            lines.append("\(omegaName) := 2*Pi*\(frequencyName):")
            assigned.insert(omegaName)
        }

        // Vs of voltage-controlled sources, before the lines that use it.
        for definition in controlDefinitions {
            lines.append(definition)
            if let symbol = definition.components(separatedBy: " := ").first { assigned.insert(symbol) }
        }

        // Which diodes conduct, as found by the app.
        let diodes = circuit.components.filter { $0.kind.isDiode }
        if !diodes.isEmpty {
            lines.append("")
            lines.append("# Dioder: en ledende diode har sin tærskelspænding over sig (anode − katode), en spærrende fører ingen strøm")
            for diode in diodes {
                lines.append("# \(diode.name) \(conducts(diode) ? "leder" : "spærrer")")
            }
        }

        // Voltage sources define the voltage on one side from the other.
        var constrainedSources: [CircuitComponent] = []
        var pendingSources = circuit.components.filter(setsVoltage)
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            for source in pendingSources {
                let plusNode = netlist.nodeOf[plusPoint(source)]
                let minusNode = netlist.nodeOf[minusPoint(source)]
                if plusNode == minusNode {
                    pendingSources.removeAll { $0.id == source.id }
                    continue
                }
                let plus = voltage(at: plusPoint(source))
                let minus = voltage(at: minusPoint(source))
                switch (isKnown(plusNode), isKnown(minusNode)) {
                case (false, true):
                    lines.append("\(plus) := \(combine(minus, "+", sourceValue(source))):")
                    assigned.insert(plus)
                case (true, false):
                    lines.append("\(minus) := \(combine(plus, "-", sourceValue(source))):")
                    assigned.insert(minus)
                case (true, true):
                    constrainedSources.append(source)
                case (false, false):
                    continue
                }
                pendingSources.removeAll { $0.id == source.id }
                madeProgress = true
            }
        }
        constrainedSources += pendingSources

        // Voltage points sharing a node with another one.
        for probe in extraProbes where !assigned.contains(probe.name) {
            lines.append("\(probe.name) := \(voltage(atNode: probe.node)):")
            assigned.insert(probe.name)
        }

        // Voltage drops between two points: V(+) − V(−). A known one becomes
        // an equation below; an unknown one is worked out from the nodes.
        var knownDrops: [(name: String, across: String)] = []
        for probe in circuit.probes {
            guard let negative = probe.negative,
                  netlist.nodeOf[probe.position] != nil, netlist.nodeOf[negative] != nil else { continue }
            let dropName = Writer.mapleName(probe.name)
            quantities[dropName] = .voltage
            let across = combine(voltage(at: probe.position), "-", voltage(at: negative))
            if assigned.contains(dropName) {
                knownDrops.append((dropName, across))
            } else {
                lines.append("\(dropName) := \(across):")
                assigned.insert(dropName)
            }
        }

        // Equations.
        var equations: [String] = []
        func addEquation(_ equation: String) {
            let name = "L\(equations.count + 1)"
            equations.append(name)
            lines.append("\(name) := \(equation):")
        }

        // Kirchhoff's current law: the currents leaving each node sum to 0.
        lines.append("")
        lines.append("# Knudepunktsligninger (Kirchhoffs strømlov): summen af strømme ud af knuden er 0")
        for node in nodesWithComponents.sorted(by: { (nodeNames[$0] ?? "").localizedStandardCompare(nodeNames[$1] ?? "") == .orderedAscending })
        where node != netlist.groundNode {
            guard let nodeName = nodeNames[node] else { continue }
            var terms: [(Double, String)] = []
            // Resistors first, then sources, e.g. (VA - VB)/R2 - I1 = 0. In AC
            // capacitors and inductors count like resistors, with their impedance.
            func isPassive(_ component: CircuitComponent) -> Bool {
                component.kind == .resistor || (component.kind.isReactive && omegaName != nil)
            }
            let ordered = circuit.components.filter(isPassive) + circuit.components.filter { !isPassive($0) }
            for component in ordered {
                let atStart = netlist.nodeOf[component.start] == node
                let atEnd = netlist.nodeOf[component.end] == node
                guard atStart != atEnd else { continue }
                if isPassive(component) {
                    let other = voltage(at: atStart ? component.end : component.start)
                    terms.append((1, passiveCurrent(component, across: "\(nodeName) - \(other)")))
                    continue
                }
                switch component.kind {
                default:
                    let flow = current(of: component)
                    terms.append((atStart ? flow.sign : -flow.sign, flow.term))
                }
            }
            let connected = circuit.components
                .filter { (netlist.nodeOf[$0.start] == node) != (netlist.nodeOf[$0.end] == node) }
                .map(\.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            lines.append("# Knude \(nodeName) (forbundet til \(connected.joined(separator: ", ")))")
            addEquation("\(sum(terms)) = 0")
        }
        for source in constrainedSources {
            let across = voltage(at: plusPoint(source)) == "0"
                ? "-\(voltage(at: minusPoint(source)))"
                : combine(voltage(at: plusPoint(source)), "-", voltage(at: minusPoint(source)))
            addEquation("\(across) = \(sourceValue(source))")
        }
        for arrow in arrowExpressions + controlCurrents {
            let terms = circuit.components.compactMap { component -> (Double, String)? in
                guard let coefficient = arrow.coefficients[component.id] else { return nil }
                let flow = current(of: component)
                return (coefficient * flow.sign, flow.term)
            }
            addEquation("\(arrow.name) = \(sum(terms))")
        }
        for drop in knownDrops {
            addEquation("\(drop.name) = \(drop.across)")
        }

        // Everything without a value is solved for.
        var unknowns: [String] = []
        unknowns += nodesWithComponents.compactMap { nodeNames[$0] }
        // A blocking diode's forward voltage doesn't take part, nor does a
        // capacitance or inductance in DC.
        unknowns += circuit.components.filter {
            $0.value == nil && (!$0.kind.isDiode || conducts($0)) && (!$0.kind.isReactive || omegaName != nil)
        }.map(name(of:))
        unknowns += circuit.components.filter { setsVoltage($0) && sourceCurrentArrows[$0.id] == nil }.map(sourceCurrentName)
        unknowns += sourceCurrentArrows.values.map(\.name)
        unknowns += arrowExpressions.map(\.name)
        unknowns += controlCurrents.map(\.name)
        var seen = Set<String>()
        unknowns = unknowns.filter { !assigned.contains($0) && seen.insert($0).inserted }
        unknowns.sort { a, b in
            let (qa, qb) = (quantities[a] ?? .current, quantities[b] ?? .current)
            return qa != qb ? qa < qb : a.localizedStandardCompare(b) == .orderedAscending
        }

        if !equations.isEmpty, !unknowns.isEmpty {
            lines.append("")
            lines.append("# Løs ligningssystemet med de kendte værdier indsat")
            lines.append("sol := solve({\(equations.joined(separator: ", "))}, {\(unknowns.joined(separator: ", "))}):")
            lines.append("")
            lines.append("# Giv alle størrelser deres værdi med enhed")
            lines.append("assign(sol):")
        }

        // The app's own solution tells how many digits each result needs.
        var computedValues: [String: Double] = [:]
        for component in circuit.components {
            if let value = solution.componentValues[component.id] { computedValues[name(of: component)] = value }
        }
        for probe in circuit.probes {
            if let value = solution.probeValues[probe.id] { computedValues[Writer.mapleName(probe.name)] = value }
        }
        for arrow in circuit.currents {
            if let value = solution.currentValues[arrow.id] { computedValues[Writer.mapleName(arrow.name)] = value }
        }

        // The results: only what the user asked for, i.e. the components,
        // voltage points and current arrows drawn without a value. Helper
        // unknowns (node voltages, source currents) stay hidden; they may
        // not even be determined, e.g. node voltages without a ground.
        let sought = Set(
            circuit.components.filter { $0.value == nil }.map(name(of:))
                + circuit.probes.filter { $0.value == nil }.map { Writer.mapleName($0.name) }
                + circuit.currents.filter { $0.value == nil }.map { Writer.mapleName($0.name) }
        )
        var listed = unknowns.filter(sought.contains)
        // Nothing asked for: show the node voltages instead.
        if listed.isEmpty { listed = unknowns.filter { quantities[$0] == .voltage } }
        if !equations.isEmpty {
            for name in listed {
                guard let quantity = quantities[name] else { continue }
                let digits = Writer.significantDigits(for: computedValues[name])
                if let base = quantity.baseUnit {
                    let unit = MapleExporter.prefixed(computedValues[name], base: base).unit
                    lines.append("\(name) := evalf(convert(\(name), 'units', '\(unit)'), \(digits));")
                    if omegaName != nil, quantity == .voltage || quantity == .current {
                        // A phasor: its amplitude and its phase in degrees.
                        lines.append("evalf(abs(\(name)/Unit('\(unit)')), \(digits))*Unit('\(unit)'), evalf(argument(\(name)/Unit('\(unit)'))*180/Pi, 4);")
                    }
                } else {
                    lines.append("\(name) := evalf(\(name), \(digits));")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Significant digits for `evalf[n]`: the fewest (up to 4) that show the
    /// value exactly, e.g. 0.5 → 1, 31 → 2, 3.65 → 3, 7.333… → 4.
    /// Values the app couldn't compute itself get 4.
    static func significantDigits(for value: Double?) -> Int {
        guard let value, value != 0, value.isFinite else { return value == 0 ? 1 : 4 }
        for digits in 1...4 {
            let magnitude = floor(log10(abs(value)))
            let scale = pow(10, Double(digits - 1) - magnitude)
            let rounded = (value * scale).rounded() / scale
            if abs(rounded - value) <= 1e-9 * abs(value) { return digits }
        }
        return 4
    }

    private func voltage(atNode node: Int) -> String {
        node == netlist.groundNode ? "0*Unit('V')" : nodeNames[node] ?? "0*Unit('V')"
    }
}
