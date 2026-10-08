#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// How each equivalent resistance (Req) on the sheet is found: the
/// independent sources are turned off, and the resistors between the two
/// points are put together in series and parallel step by step. What can't be
/// reduced that way (a bridge) is worked out by sending a test current of 1 A
/// in at A and out at B, with node voltages. Gives the same values as
/// `CircuitSolver.equivalentResistance`, which the sheet shows.
nonisolated enum EquivalentWalkthrough {
    static func make(for circuit: Circuit) -> WalkResult {
        let circuit = circuit.resolvingSwitches()
        guard !circuit.equivalents.isEmpty else {
            return .unavailable("Sæt en samlet modstand (Req) mellem to punkter på kredsløbet for at se, hvordan den findes.")
        }
        let netlist = Netlist(circuit)
        let solution = CircuitSolver.solve(circuit)
        var sections: [WalkSection] = []
        var code: [String] = []
        var parts: [CircuitComponent] = []
        for equivalent in circuit.equivalents {
            let walk = Single(equivalent: equivalent, circuit: circuit, netlist: netlist, solution: solution)
            sections += walk.sections
            if !walk.maple.isEmpty { code += [""] + walk.maple }
            for part in walk.parts where !parts.contains(where: { $0.id == part.id }) { parts.append(part) }
        }
        guard !code.isEmpty else { return .steps(sections) }
        return .steps(sections, maple: (mapleHeader(parts, solution: solution) + code).joined(separator: "\n"))
    }

    /// Units, the frequency in AC, and the values of the parts the Reqs are made of.
    private static func mapleHeader(_ parts: [CircuitComponent], solution: CircuitSolution) -> [String] {
        var lines = ["with(Units):", "unassign(anames(user)):", "", "# Kendte værdier"]
        if let frequency = solution.frequency, parts.contains(where: { $0.kind.isReactive }) {
            lines.append("f := \(MapleExporter.quantity(frequency, base: "Hz")):")
            lines.append("omega := 2*Pi*f:")
        }
        for part in parts {
            let value = part.value ?? solution.componentValues[part.id] ?? 0
            let base = switch part.kind {
            case .capacitor: "F"
            case .inductor: "H"
            default: "ohm"
            }
            lines.append("\(MapleExporter.valueName(of: part)) := \(MapleExporter.quantity(value, base: base)):")
        }
        return lines
    }

    /// A list in Danish: "R1, R2 og R3".
    fileprivate static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " og " + (names.last ?? "")
    }
}

/// One branch of the network between A and B: a component, or several put
/// together in series or parallel.
nonisolated private struct Branch {
    var p: Int
    var q: Int
    var z: Complex
    /// Its name in formulas: R_{1}, Z_{C1} or R_{12} for R1 and R2 together.
    var symbol: String
    /// Its value in Maple: R1, (1/(I*omega*C1)), or the name of a combination.
    var maple: String
    /// The names of the components it's made of.
    var members: [String]
    var isReactive: Bool

    func other(_ node: Int) -> Int { p == node ? q : p }
}

/// The walkthrough of one Req.
nonisolated private struct Single {
    var sections: [WalkSection] = []
    var maple: [String] = []
    /// The resistors, capacitors and inductors that take part.
    var parts: [CircuitComponent] = []

    init(equivalent: EquivalentResistance, circuit: Circuit, netlist: Netlist, solution: CircuitSolution) {
        let name = WalkFormat.name(equivalent.name)
        let result = CircuitSolver.equivalentResistance(
            between: equivalent.start, and: equivalent.end, in: circuit, netlist: netlist, solution: solution
        )
        let target: Complex
        switch result {
        case .value(let resistance, _): target = Complex(resistance)
        case .impedance(let impedance, _): target = impedance
        case .notOnCircuit:
            sections = [WalkSection(title: equivalent.name, lines: [.text("Et af punkterne for \(equivalent.name) sidder ikke på kredsløbet. Slet den og sæt den igen.")])]
            return
        case .notConnected:
            sections = [WalkSection(title: equivalent.name, lines: [.text("Der er ingen vej gennem modstande mellem de to punkter for \(equivalent.name).")])]
            return
        case .unknownValues(let names):
            sections = [WalkSection(title: equivalent.name, lines: [.text("Værdien af \(EquivalentWalkthrough.list(names)) kendes ikke endnu, så \(equivalent.name) kan ikke findes.")])]
            return
        case .dependentSources(let names):
            sections = [WalkSection(title: equivalent.name, lines: [.text("\(EquivalentWalkthrough.list(names)) indgår, men \(equivalent.name) kan ikke findes. Tjek at styrede kilder har deres styrepunkter på kredsløbet.")])]
            return
        }

        let omega = solution.frequency.map { 2 * .pi * $0 }
        func value(_ component: CircuitComponent) -> Double? { component.value ?? solution.componentValues[component.id] }
        func impedance(_ component: CircuitComponent) -> Complex? { value(component).map { component.kind.impedance($0, omega: omega) } }
        func node(_ point: GridPoint) -> Int { netlist.nodeOf[point, default: -1] }

        // Shorts join their two nodes, as in the solver: 0 Ω, and inductors in DC.
        var parent: [Int: Int] = [:]
        func find(_ n: Int) -> Int {
            var root = n
            while let next = parent[root], next != root { root = next }
            return root
        }
        func join(_ p: Int, _ q: Int) {
            let rootP = find(p), rootQ = find(q)
            if rootP != rootQ { parent[rootP] = rootQ }
        }
        for component in circuit.components {
            switch component.kind {
            case .resistor where value(component) == 0: join(node(component.start), node(component.end))
            case .inductor where omega == nil || impedance(component)?.magnitude == 0: join(node(component.start), node(component.end))
            default: break
            }
        }
        guard let pointA = netlist.node(at: equivalent.start), let pointB = netlist.node(at: equivalent.end) else { return }
        // A voltage source right between the points is taken out, the others shorted.
        let ends = Set([find(pointA), find(pointB)])
        let voltageSources = circuit.components.filter { $0.kind == .voltageSource || $0.kind == .signalGenerator }
        let removed = voltageSources.filter { Set([find(node($0.start)), find(node($0.end))]) == ends }
        let shorted = voltageSources.filter { source in !removed.contains { $0.id == source.id } }
        for source in shorted { join(node(source.start), node(source.end)) }
        let currentSources = circuit.components.filter { $0.kind == .currentSource }
        let a = find(pointA), b = find(pointB)

        // What the sources become.
        var setup: [WalkLine] = [.text("\(equivalent.name) er modstanden set mellem punkt A og punkt B. Først slukkes de uafhængige kilder:")]
        if !shorted.isEmpty {
            setup.append(.text("Spændingskilder kortsluttes (erstattes af en ledning): \(EquivalentWalkthrough.list(shorted.map(\.name)))."))
        }
        if !currentSources.isEmpty {
            setup.append(.text("Strømkilder afbrydes (tages ud): \(EquivalentWalkthrough.list(currentSources.map(\.name)))."))
        }
        for source in removed {
            setup.append(.text("\(source.name) sidder direkte mellem A og B og tages ud – det er den, \(equivalent.name) ses fra."))
        }
        if shorted.isEmpty, currentSources.isEmpty, removed.isEmpty {
            setup.append(.text("Der er ingen uafhængige kilder at slukke."))
        }
        if omega == nil {
            if circuit.components.contains(where: { $0.kind == .capacitor }) {
                setup.append(.text("I DC fører en kondensator ingen strøm og regnes som en afbrydelse."))
            }
            if circuit.components.contains(where: { $0.kind == .inductor }) {
                setup.append(.text("I DC har en spole ingen spænding over sig og regnes som en kortslutning."))
            }
        }

        let members = circuit.components
            .filter { result.resistors.contains($0.id) && ($0.kind == .resistor || $0.kind.isReactive) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        parts = members.filter { impedance($0).map { $0.magnitude > 0 && $0.magnitude.isFinite } ?? false }

        if a == b {
            setup.append(.text("A og B er nu forbundet direkte (gennem ledninger, kortsluttede kilder eller 0 Ω), så der er ingen modstand mellem dem:"))
            setup.append(.math("\(name) = 0 [[Ω]]"))
            sections = [WalkSection(title: equivalent.name, lines: setup)]
            parts = []
            return
        }

        // The values that take part, and in AC the impedances.
        let sourceLineCount = setup.count
        if let frequency = solution.frequency, parts.contains(where: { $0.kind.isReactive }) {
            setup.append(.text("Kredsløbet regnes med fasorer ved signalgeneratorens frekvens:"))
            setup.append(.math("f = \(WalkFormat.quantity(frequency, symbol: "Hz"));\\quad \\omega = 2 \\pi f = \(WalkFormat.number(2 * .pi * frequency)) [[rad/s]]"))
        }
        setup.append(.text(parts.contains(where: { $0.kind.isReactive }) ? "Komponenterne, der indgår:" : "Modstandene, der indgår:"))
        for part in parts {
            let symbol = WalkFormat.name(part.name)
            let size = value(part) ?? 0
            switch part.kind {
            case .capacitor:
                setup.append(.math("\(symbol) = \(WalkFormat.quantity(size, symbol: "F"));\\quad Z_{\(part.name)} = \\frac{1}{j \\omega \(symbol)} = \(WalkFormat.quantity(impedance(part) ?? .zero, .ohm))"))
            case .inductor:
                setup.append(.math("\(symbol) = \(WalkFormat.quantity(size, symbol: "H"));\\quad Z_{\(part.name)} = j \\omega \(symbol) = \(WalkFormat.quantity(impedance(part) ?? .zero, .ohm))"))
            default:
                setup.append(.math("\(symbol) = \(WalkFormat.quantity(size, .ohm))"))
            }
        }
        let shorts = members.filter { impedance($0)?.magnitude == 0 }
        if !shorts.isEmpty {
            setup.append(.text("\(EquivalentWalkthrough.list(shorts.map(\.name))) er 0 Ω og virker som en ledning."))
        }

        var branches: [Branch] = parts.compactMap { part in
            let p = find(node(part.start)), q = find(node(part.end))
            guard p != q, let z = impedance(part) else { return nil }
            let maple = switch part.kind {
            case .capacitor: "(1/(I*omega*\(MapleExporter.valueName(of: part))))"
            case .inductor: "(I*omega*\(MapleExporter.valueName(of: part)))"
            default: MapleExporter.valueName(of: part)
            }
            let symbol = part.kind == .resistor ? WalkFormat.name(part.name) : "Z_{\(part.name)}"
            return Branch(p: p, q: q, z: z, symbol: symbol, maple: maple, members: [part.name], isReactive: part.kind.isReactive)
        }

        // Resistors next to the ones taking part that carry none of the current.
        let touched = Set(branches.flatMap { [$0.p, $0.q] })
        let unused = circuit.components.filter { component in
            (component.kind == .resistor || (omega != nil && component.kind.isReactive))
                && !result.resistors.contains(component.id)
                && (touched.contains(find(node(component.start))) || touched.contains(find(node(component.end))))
        }
        if !unused.isEmpty {
            setup.append(.text("\(EquivalentWalkthrough.list(unused.map(\.name))) fører ingen strøm, når der sættes en spænding mellem A og B (de hænger kun fast i den ene ende, er kortsluttet eller sidder i en bro i balance), og tæller ikke med."))
        }
        sections.append(WalkSection(title: "\(equivalent.name): kilderne slukkes", lines: setup))

        // Series and parallel, one step at a time.
        var steps: [WalkLine] = []
        while let step = Self.reduce(&branches, a: a, b: b) {
            steps += step.lines
            maple.append(step.maple)
        }
        let unit: PhysicalUnit = .ohm
        var found: Complex?
        if branches.count == 1, let last = branches.first, Set([last.p, last.q]) == Set([a, b]) {
            found = last.z
            if steps.isEmpty {
                steps.append(.text("Kun \(WalkFormat.plain(last.symbol)) ligger mellem A og B:"))
            } else {
                steps.append(.text("Nu er der kun én modstand tilbage mellem A og B:"))
            }
            steps.append(.math("\(name) = \(last.symbol) = \(WalkFormat.result(last.z, unit))"))
            maple.append(mapleResult(equivalent.name, last.maple, value: last.z, isAC: omega != nil))
            sections.append(WalkSection(title: "\(equivalent.name): serie og parallel", lines: steps))
        } else if !branches.isEmpty {
            if !steps.isEmpty { sections.append(WalkSection(title: "\(equivalent.name): serie og parallel", lines: steps)) }
            let test = Self.testCurrent(branches, a: a, b: b, name: name)
            found = test.value
            sections.append(WalkSection(title: "\(equivalent.name): teststrøm", lines: test.lines))
            maple.append("# \(equivalent.name) kan ikke skrives med serie og parallel alene; se teststrømmen i gennemgangen.")
        }

        // Controlled sources or diodes take part: the solver's test source.
        let matches = found.map { ($0 - target).magnitude <= 1e-6 * max(target.magnitude, 1e-9) } ?? false
        if !matches {
            sections = [WalkSection(title: "\(equivalent.name): kilderne slukkes", lines: Array(setup.prefix(sourceLineCount)))]
            sections.append(WalkSection(title: "\(equivalent.name): testkilde", lines: [
                .text("Styrede kilder eller dioder indgår, så \(equivalent.name) kan ikke findes med serie og parallel. De uafhængige kilder slukkes, de styrede bliver tændt, og dioderne står i deres beregnede tilstand. Så sendes en teststrøm på 1 A ind i A og ud i B, og spændingen mellem A og B findes med knudepunktsmetoden:"),
                .math("\(name) = \\frac{V_{AB}}{1 [[A]]} = \(WalkFormat.result(target, unit))"),
            ]))
            maple = []
            parts = []
        }
    }

    /// The Maple line that prints a Req in its unit, and in AC its size and angle.
    private func mapleResult(_ name: String, _ expression: String, value: Complex, isAC: Bool) -> String {
        let size = WalkFormat.isReal(value) ? value.re : value.magnitude
        let digits = MapleExporter.significantDigits(for: size)
        let unit = MapleExporter.prefixed(size, base: "ohm").unit
        let mapleName = MapleExporter.name(name)
        var result = "\(mapleName) := evalf(convert(\(expression), 'units', '\(unit)'), \(digits));"
        if isAC {
            result += "\nevalf(abs(\(mapleName)/Unit('\(unit)')), \(digits))*Unit('\(unit)'), evalf(argument(\(mapleName)/Unit('\(unit)'))*180/Pi, 4);"
        }
        return result
    }

    // MARK: Series and parallel

    /// The name of branches put together: R_{12} for R1 and R2, R_{1,10}
    /// when a number has more digits, Z_{R1,C1} for other names.
    private static func combinedSymbol(_ members: [String], isReactive: Bool) -> String {
        let letter = isReactive ? "Z" : "R"
        let numbers = members.map { $0.dropFirst() }
        if !isReactive, members.allSatisfy({ $0.hasPrefix("R") && $0.count > 1 && $0.dropFirst().allSatisfy(\.isNumber) }) {
            let separator = numbers.allSatisfy { $0.count == 1 } ? "" : ","
            return "\(letter)_{\(numbers.joined(separator: separator))}"
        }
        return "\(letter)_{\(members.joined(separator: ","))}"
    }

    /// Puts two or more branches together into one, in place of the first.
    private static func combine(_ branches: inout [Branch], _ indices: [Int], p: Int, q: Int, z: Complex) -> Branch {
        let group = indices.map { branches[$0] }
        let members = group.flatMap(\.members)
        let isReactive = group.contains(where: \.isReactive)
        let symbol = combinedSymbol(members, isReactive: isReactive)
        let combined = Branch(p: p, q: q, z: z, symbol: symbol, maple: MapleExporter.name(symbol), members: members, isReactive: isReactive)
        let first = indices.min() ?? 0
        branches[first] = combined
        for index in indices.sorted(by: >) where index != first { branches.remove(at: index) }
        return combined
    }

    /// One step: branches between the same two nodes in parallel, otherwise
    /// a chain of branches in series. `nil` when neither is left.
    private static func reduce(_ branches: inout [Branch], a: Int, b: Int) -> (lines: [WalkLine], maple: String)? {
        func incident(_ node: Int) -> [Int] { branches.indices.filter { branches[$0].p == node || branches[$0].q == node } }
        let unit: PhysicalUnit = .ohm

        // Parallel: the same two nodes.
        for index in branches.indices {
            let pair = Set([branches[index].p, branches[index].q])
            let group = branches.indices.filter { Set([branches[$0].p, branches[$0].q]) == pair }
            guard group.count > 1 else { continue }
            let parts = group.map { branches[$0] }
            let z = Complex.one / parts.reduce(Complex.zero) { $0 + Complex.one / $1.z }
            let (p, q) = (branches[index].p, branches[index].q)
            let combined = combine(&branches, group, p: p, q: q, z: z)
            let symbols = parts.map(\.symbol)
            let values = parts.map { WalkFormat.quantityFactor($0.z, unit) }
            let formula: (([String]) -> String)
            let maple: String
            if parts.count == 2 {
                formula = { "\\frac{\($0[0]) \\cdot \($0[1])}{\($0[0]) + \($0[1])}" }
                maple = "\(combined.maple) := \(parts[0].maple)*\(parts[1].maple)/(\(parts[0].maple) + \(parts[1].maple)):"
            } else {
                formula = { "\\frac{1}{\($0.map { "\\frac{1}{\($0)}" }.joined(separator: " + "))}" }
                maple = "\(combined.maple) := 1/(\(parts.map { "1/\($0.maple)" }.joined(separator: " + "))):"
            }
            return ([
                .text("\(EquivalentWalkthrough.list(symbols.map(WalkFormat.plain))) er parallelle (forbundet mellem de samme to knudepunkter):"),
                .math("\(combined.symbol) = \(symbols.joined(separator: " \\parallel ")) = \(formula(symbols)) = \(formula(values)) = \(WalkFormat.result(z, unit))"),
            ], maple)
        }

        // Series: a chain through nodes other than A and B with only two branches.
        let nodes = Set(branches.flatMap { [$0.p, $0.q] }).subtracting([a, b]).sorted()
        func isLink(_ node: Int) -> Bool { node != a && node != b && incident(node).count == 2 }
        guard let start = nodes.first(where: isLink) else { return nil }
        var visited: Set<Int> = [start]
        /// The branches after `branch` going away from `node`, along the chain.
        func extend(_ branch: Int, from node: Int) -> [Int] {
            var chain: [Int] = []
            var current = branch
            var at = branches[current].other(node)
            while isLink(at), !visited.contains(at), let next = incident(at).first(where: { $0 != current }) {
                visited.insert(at)
                chain.append(next)
                current = next
                at = branches[next].other(at)
            }
            return chain
        }
        let pair = incident(start)
        let left = extend(pair[0], from: start)
        let right = extend(pair[1], from: start)
        let chain = left.reversed() + [pair[0], pair[1]] + right
        // The two ends of the chain are the nodes that appear once.
        var counts: [Int: Int] = [:]
        for index in chain { for node in [branches[index].p, branches[index].q] { counts[node, default: 0] += 1 } }
        let outer = counts.filter { $0.value == 1 }.map(\.key).sorted()
        guard outer.count == 2 else { return nil }
        let parts = chain.map { branches[$0] }
        let z = parts.reduce(Complex.zero) { $0 + $1.z }
        let combined = combine(&branches, chain, p: outer[0], q: outer[1], z: z)
        let symbols = parts.map(\.symbol)
        let values = parts.map { WalkFormat.quantityFactor($0.z, unit) }
        return ([
            .text("\(EquivalentWalkthrough.list(symbols.map(WalkFormat.plain))) sidder i serie (den samme strøm løber gennem dem):"),
            .math("\(combined.symbol) = \(symbols.joined(separator: " + ")) = \(values.joined(separator: " + ")) = \(WalkFormat.result(z, unit))"),
        ], "\(combined.maple) := \(parts.map(\.maple).joined(separator: " + ")):")
    }

    // MARK: Test current

    /// A network that isn't series and parallel: 1 A in at A and out at B,
    /// with B as 0 V. Kirchhoff's current law in each node gives the node
    /// voltages, and Req is V_A / 1 A.
    private static func testCurrent(_ branches: [Branch], a: Int, b: Int, name: String) -> (lines: [WalkLine], value: Complex?) {
        let others = Set(branches.flatMap { [$0.p, $0.q] }).subtracting([a, b]).sorted()
        var voltage: [Int: String] = [a: "V_{A}", b: "0"]
        var letters = WalkFormat.letters.filter { $0 != "A" && $0 != "B" }.makeIterator()
        for node in others { voltage[node] = "V_{\(letters.next() ?? "X")}" }
        let unknowns = [a] + others
        let order = unknowns.compactMap { voltage[$0] }

        var lines: [WalkLine] = [
            .text("Resten kan ikke deles op i serie og parallel (fx en bro). Send i stedet en teststrøm på 1 A ind i A og ud i B. Med B som 0 V giver Kirchhoffs strømlov en ligning i hvert af de andre knudepunkter: strømmene ud gennem modstandene er lig med strømmen, der sendes ind."),
        ]
        var equations: [(label: String, equation: LinearEquation)] = []
        for node in unknowns {
            let own = voltage[node] ?? "0"
            var terms: [String] = []
            var equation = LinearEquation()
            for branch in branches where branch.p == node || branch.q == node {
                let other = branch.other(node)
                let otherName = voltage[other] ?? "0"
                terms.append("\\frac{\(own) - \(otherName)}{\(branch.symbol)}")
                let y = Complex.one / branch.z
                equation.add(own, y)
                if other != b { equation.add(otherName, -y) }
            }
            equation.constant = node == a ? .one : .zero
            equation.removeZeros()
            let label = WalkFormat.plain(own)
            lines.append(.text("Knudepunkt \(label):"))
            lines.append(.math("\(terms.joined(separator: " + ")) = \(node == a ? "1 [[A]]" : "0")"))
            lines.append(.math(equation.latex(order: order)))
            equations.append((label, equation))
        }
        guard let solved = Substitution.solve(equations, unknowns: order), let va = solved.values["V_{A}"] else {
            lines.append(.text("Ligningerne har ingen entydig løsning."))
            return (lines, nil)
        }
        lines += solved.lines
        lines.append(.text("Spændingen mellem A og B divideret med teststrømmen er den samlede modstand:"))
        lines.append(.math("\(name) = \\frac{V_{A}}{1 [[A]]} = \(WalkFormat.result(va, .ohm))"))
        return (lines, va)
    }
}
