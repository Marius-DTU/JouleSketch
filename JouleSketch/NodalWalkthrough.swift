import Foundation

/// The node-voltage method: Kirchhoff's current law in every node, with the
/// currents written with Ohm's law, solved by gradual substitution.
nonisolated enum NodalWalkthrough {
    static func make(_ model: WalkModel) -> WalkResult {
        var setup: [WalkLine] = [referenceLine(model)]
        let names = model.nodes.compactMap { model.nodeName[$0] }
        if !names.isEmpty {
            setup.append(.text("De ubekendte er knudespændingerne i de øvrige knuder:"))
            setup.append(.math(names.joined(separator: ",\\; ")))
        }
        let controlCurrents = model.controls.values.filter { if case .current = $0.kind { true } else { false } }
        if !controlCurrents.isEmpty {
            setup.append(.text("De styrende strømme er også ubekendte, med hver sin ligning:"))
            setup.append(.math(controlCurrents.map(\.latex).sorted().joined(separator: ",\\; ")))
        }
        setup += model.knownValueLines()

        let system: System
        switch equations(model, value: \.value) {
        case .failure(let error): return .unavailable(error.text)
        case .success(let result): system = result
        }
        guard let solution = Substitution.solve(system.equations, unknowns: system.unknowns) else {
            return .unavailable("Knudeligningerne har ikke én løsning. Er hele kredsløbet forbundet?")
        }
        let nodeValues = values(model, solution.values)
        let controls = controlValues(model, nodeValues: nodeValues, solved: solution.values)
        let summary = model.nodes.compactMap { node in
            model.nodeName[node].map { "\($0) = \(WalkFormat.quantity(nodeValues[node] ?? 0, .volt))" }
        }
        return .steps([
            WalkSection(title: "1. Opsætning", lines: setup),
            WalkSection(title: "2. Knudeligninger", lines: system.lines),
            WalkSection(title: "3. Løsning ved gradvis substitution", lines: solution.lines),
            WalkSection(
                title: "4. Resultat",
                lines: [.text("Knudespændingerne:"), .math(summary.joined(separator: ";\\quad ")), .text("Det, der blev spurgt om:")]
                    + targetLines(model, nodeValues: nodeValues, value: \.value, controls: controls).lines
            ),
        ])
    }

    static func referenceLine(_ model: WalkModel) -> WalkLine {
        model.referenceIsGround
            ? .text("Referencen (0 V) er knuden med stel-symbolet.")
            : .text("Der er intet stel, så knuden med flest forbindelser vælges som reference (0 V).")
    }

    struct System {
        var lines: [WalkLine] = []
        var equations: [(label: String, equation: LinearEquation)] = []
        /// Node voltages, then the controlling currents of controlled sources.
        var unknowns: [String] = []
        /// The same equations as Maple lines, their names and the unknowns.
        var maple: [String] = []
        var mapleLabels: [String] = []
        var mapleUnknowns: [String] = []
    }

    /// A node's voltage in Maple, with `suffix` after it; 0 for the reference.
    static func mapleNode(_ node: Int, _ model: WalkModel, suffix: String) -> String {
        guard node != model.reference, let name = model.nodeName[node] else { return "0" }
        return MapleExporter.name(name) + suffix
    }

    /// What a controlled source depends on, as a linear expression in the
    /// unknowns (node voltages and controlling currents).
    struct ControlTerms {
        var terms: [String: Double]
        /// V_{s} or I_{x}.
        var latex: String
        /// Written with the unknowns: (V_A - V_B), or I_{x}.
        var numeric: String
        var maple: String
    }

    static func controlTerms(_ part: WalkPart, _ model: WalkModel, suffix: String) -> ControlTerms? {
        guard let control = model.controls[part.component.id] else { return nil }
        switch control.kind {
        case .voltage(let plus, let minus):
            var terms: [String: Double] = [:]
            if plus != model.reference, let name = model.nodeName[plus] { terms[name, default: 0] += 1 }
            if minus != model.reference, let name = model.nodeName[minus] { terms[name, default: 0] -= 1 }
            return ControlTerms(
                terms: terms, latex: control.latex,
                numeric: "(\(model.voltageName(plus)) - \(model.voltageName(minus)))",
                maple: "(\(mapleNode(plus, model, suffix: suffix)) - \(mapleNode(minus, model, suffix: suffix)))"
            )
        case .current:
            return ControlTerms(terms: [control.latex: 1], latex: control.latex, numeric: control.latex, maple: control.maple + suffix)
        }
    }

    /// A component's current from its start to its end terminal as a linear
    /// expression in the unknowns, for Kirchhoff's current law and the
    /// controlling currents. `nil` for sources that set a voltage.
    struct LinearCurrent {
        var terms: [String: Double] = [:]
        var constant = 0.0
        var latex: String
        var numeric: String
        var maple: String
    }

    static func linearCurrent(_ part: WalkPart, _ model: WalkModel, value: (WalkPart) -> Double, suffix: String) -> LinearCurrent? {
        func v(_ node: Int) -> String? { node == model.reference ? nil : model.nodeName[node] }
        switch part.kind {
        case .resistor:
            let r = value(part)
            var current = LinearCurrent(
                latex: "\\frac{\(model.voltageName(part.start)) - \(model.voltageName(part.end))}{\(part.symbol)}",
                numeric: "\\frac{\(model.voltageName(part.start)) - \(model.voltageName(part.end))}{\(WalkFormat.quantity(r, .ohm))}",
                maple: "(\(mapleNode(part.start, model, suffix: suffix)) - \(mapleNode(part.end, model, suffix: suffix)))/\(part.mapleName)"
            )
            if let a = v(part.start) { current.terms[a, default: 0] += 1 / r }
            if let b = v(part.end) { current.terms[b, default: 0] -= 1 / r }
            return current
        case .currentSource:
            let j = value(part)
            return LinearCurrent(constant: j, latex: part.symbol, numeric: WalkFormat.quantity(j, .ampere), maple: j == 0 ? "0*Unit('A')" : part.mapleName)
        case .vccs, .cccs:
            let gain = value(part)
            guard let control = controlTerms(part, model, suffix: suffix) else { return nil }
            return LinearCurrent(
                terms: control.terms.mapValues { $0 * gain },
                latex: "\(part.valueSymbol) \\cdot \(control.latex)",
                numeric: "\(WalkFormat.number(gain)) \\cdot \(control.numeric)",
                maple: "\(part.mapleName)*\(control.maple)"
            )
        case .voltageSource, .vcvs, .ccvs:
            // Kirchhoff's current law in a node where it's the only source
            // setting a voltage: its current is what the others carry away.
            for node in [part.start, part.end] {
                let others = model.parts.filter {
                    $0.component.id != part.component.id && ($0.start == node) != ($0.end == node)
                }
                guard !others.contains(where: { $0.kind.setsVoltage }) else { continue }
                var current = LinearCurrent(latex: "", numeric: "", maple: "")
                var latex: [(negative: Bool, body: String)] = []
                var numeric: [(negative: Bool, body: String)] = []
                var maple: [(negative: Bool, body: String)] = []
                for other in others {
                    guard let otherCurrent = linearCurrent(other, model, value: value, suffix: suffix) else { return nil }
                    // It leaves the node at its start terminal, so it's minus (at
                    // the start) or plus (at the end) what flows out through the others.
                    let positive = (other.start == node) != (node == part.start)
                    let sign = positive ? 1.0 : -1.0
                    for (name, c) in otherCurrent.terms { current.terms[name, default: 0] += sign * c }
                    current.constant += sign * otherCurrent.constant
                    latex.append((!positive, otherCurrent.latex))
                    numeric.append((!positive, otherCurrent.numeric))
                    maple.append((!positive, otherCurrent.maple))
                }
                current.latex = latex.isEmpty ? "0" : "(\(joined(latex)))"
                current.numeric = numeric.isEmpty ? "0" : "(\(joined(numeric)))"
                current.maple = maple.isEmpty ? "0*Unit('A')" : "(\(joined(maple)))"
                return current
            }
            return nil
        default:
            return nil
        }
    }

    /// The node equations. `value` gives each component's value, so
    /// superposition can switch sources off (0 V is a short, 0 A is open).
    /// `mapleSuffix` goes after the Maple names, so each source's circuit
    /// in superposition gets its own.
    static func equations(_ model: WalkModel, value: (WalkPart) -> Double, mapleSuffix: String = "") -> Result<System, WalkError> {
        var system = System()
        system.unknowns = model.nodes.compactMap { model.nodeName[$0] }
        system.mapleUnknowns = model.nodes.map { mapleNode($0, model, suffix: mapleSuffix) }
        // The controlling currents are unknowns too, each with its own equation.
        var controlCurrents: [(part: WalkPart, control: WalkControl, coefficients: [UUID: Double])] = []
        for part in model.parts {
            guard let control = model.controls[part.component.id], case .current(let coefficients) = control.kind,
                  !system.unknowns.contains(control.latex) else { continue }
            system.unknowns.append(control.latex)
            system.mapleUnknowns.append(control.maple + mapleSuffix)
            controlCurrents.append((part, control, coefficients))
        }
        func v(_ node: Int) -> String? { node == model.reference ? nil : model.nodeName[node] }
        func mv(_ node: Int) -> String { mapleNode(node, model, suffix: mapleSuffix) }
        func label() -> String { "L\(system.equations.count + 1)" }
        func addMaple(_ equation: String) {
            let name = "\(label())\(mapleSuffix)"
            system.mapleLabels.append(name)
            system.maple.append("\(name) := \(equation):")
        }
        /// "V_A - V_B", with 0 for the reference: "V_A - 0", "0 - V_D".
        func difference(_ a: Int, _ b: Int) -> String {
            "\(v(a) ?? "0") - \(v(b) ?? "0")"
        }

        // Nodes joined by sources that set a voltage belong together.
        let voltageSources = model.parts.filter { $0.kind.setsVoltage }
        var parent: [Int: Int] = [:]
        func find(_ n: Int) -> Int {
            var root = n
            while let next = parent[root], next != root { root = next }
            return root
        }
        for source in voltageSources where find(source.start) != find(source.end) {
            parent[find(source.start)] = find(source.end)
        }
        let allNodes = [model.reference] + model.nodes
        let groups = Dictionary(grouping: allNodes, by: find)
            .values
            .map { $0.sorted() }
            .sorted { ($0.contains(model.reference) ? -1 : $0[0]) < ($1.contains(model.reference) ? -1 : $1[0]) }

        for members in groups {
            let memberSet = Set(members)
            let sources = voltageSources.filter { memberSet.contains($0.start) }
            guard sources.count == members.count - 1 else {
                return .failure(.message("Spændingskilder sidder i en løkke uden andre komponenter, så knudepunktsmetoden kan ikke bruges."))
            }
            let hasReference = memberSet.contains(model.reference)
            if !sources.isEmpty {
                let names = sources.map(\.component.name).joined(separator: ", ")
                let plural = sources.count > 1
                system.lines.append(.text(hasReference
                    ? "Spændingskilde\(plural ? "rne" : "n") \(names) sidder på referencen og giver knudespænding\(plural ? "erne" : "en"):"
                    : "Superknude: \(names) forbinder \(members.compactMap { model.nodeName[$0].map(WalkFormat.plain) }.joined(separator: " og ")). Kilderne giver sammenhængen mellem knuderne, og strømloven skrives for hele superknuden."))
            }
            for source in sources {
                var equation = LinearEquation()
                if let plus = v(source.end) { equation.add(plus, 1) }
                if let minus = v(source.start) { equation.add(minus, -1) }
                if source.kind == .voltageSource {
                    let e = value(source)
                    equation.constant = e
                    let short = e == 0 && source.value != 0 ? " (kortsluttet)" : ""
                    system.lines.append(.text("(\(label())) \(source.component.name)\(short):"))
                    system.lines.append(.math("\(difference(source.end, source.start)) = \(source.symbol) = \(WalkFormat.quantity(e, .volt))"))
                    addMaple("\(mv(source.end)) - \(mv(source.start)) = \(e == 0 ? "0*Unit('V')" : source.mapleName)")
                } else {
                    // A controlled voltage source: the gain times what controls it.
                    let gain = value(source)
                    guard let control = controlTerms(source, model, suffix: mapleSuffix) else {
                        return .failure(.message("\(source.component.name) mangler sin styring."))
                    }
                    for (name, c) in control.terms { equation.add(name, -gain * c) }
                    system.lines.append(.text("(\(label())) \(source.component.name) (styret):"))
                    system.lines.append(.math("\(difference(source.end, source.start)) = \(source.valueSymbol) \\cdot \(control.latex) = \(WalkFormat.number(gain)) \\cdot \(control.numeric)"))
                    system.lines.append(.math(equation.latex(order: system.unknowns)))
                    addMaple("\(mv(source.end)) - \(mv(source.start)) = \(source.mapleName)*\(control.maple)")
                }
                equation.terms = equation.terms.filter { abs($0.value) > 1e-12 }
                system.equations.append((label(), equation))
            }
            guard !hasReference else { continue }

            // Kirchhoff's current law for the node or supernode.
            var symbolic: [(negative: Bool, body: String)] = []
            var numeric: [(negative: Bool, body: String)] = []
            var maple: [(negative: Bool, body: String)] = []
            var equation = LinearEquation()
            for part in model.parts where !part.kind.setsVoltage {
                let startInside = memberSet.contains(part.start)
                let endInside = memberSet.contains(part.end)
                guard startInside != endInside else { continue }
                let (inside, outside) = startInside ? (part.start, part.end) : (part.end, part.start)
                if part.kind == .resistor {
                    let r = value(part)
                    symbolic.append((false, "\\frac{\(difference(inside, outside))}{\(part.symbol)}"))
                    numeric.append((false, "\\frac{\(difference(inside, outside))}{\(WalkFormat.quantity(r, .ohm))}"))
                    maple.append((false, "(\(mv(inside)) - \(mv(outside)))/\(part.mapleName)"))
                    if let x = v(inside) { equation.add(x, 1 / r) }
                    if let y = v(outside) { equation.add(y, -1 / r) }
                    continue
                }
                // Sources push current from their start to their end terminal,
                // so it leaves the node at the start.
                guard let current = linearCurrent(part, model, value: value, suffix: mapleSuffix) else {
                    return .failure(.message("\(part.component.name) mangler sin styring."))
                }
                if part.kind == .currentSource, current.constant == 0 { continue }
                let leaving = startInside
                let sign = leaving ? 1.0 : -1.0
                symbolic.append((!leaving, current.latex))
                numeric.append((!leaving, current.numeric))
                maple.append((!leaving, current.maple))
                for (name, c) in current.terms { equation.add(name, sign * c) }
                equation.constant -= sign * current.constant
            }
            guard !symbolic.isEmpty else { continue }
            equation.terms = equation.terms.filter { abs($0.value) > 1e-12 }
            let where_ = members.count == 1 ? "knude \(WalkFormat.plain(model.nodeName[members[0]] ?? ""))" : "superknuden"
            system.lines.append(.text("(\(label())) Strømloven for \(where_): summen af strømmene ud af \(members.count == 1 ? "knuden" : "superknuden") er 0."))
            system.lines.append(.math("\(joined(symbolic)) = 0"))
            system.lines.append(.math("\(joined(numeric)) = 0"))
            system.lines.append(.text("Samlet efter de ubekendte (i A):"))
            system.lines.append(.math(equation.latex(order: system.unknowns)))
            addMaple("\(joined(maple)) = 0")
            system.equations.append((label(), equation))
        }

        // The controlling currents, from the currents where their Is points sit.
        for (part, control, coefficients) in controlCurrents {
            var equation = LinearEquation()
            equation.add(control.latex, 1)
            var symbolic: [(negative: Bool, body: String)] = []
            var numeric: [(negative: Bool, body: String)] = []
            var maple: [(negative: Bool, body: String)] = []
            for other in model.parts {
                let coefficient = coefficients[other.component.id] ?? 0
                guard abs(coefficient) > 1e-9 else { continue }
                guard let current = linearCurrent(other, model, value: value, suffix: mapleSuffix) else {
                    return .failure(.message("\(control.plain) for \(part.component.name) går gennem en spændingskilde og kan ikke skrives med knudespændingerne."))
                }
                symbolic.append((coefficient < 0, current.latex))
                numeric.append((coefficient < 0, current.numeric))
                maple.append((coefficient < 0, current.maple))
                for (name, c) in current.terms { equation.add(name, -coefficient * c) }
                equation.constant += coefficient * current.constant
            }
            equation.terms = equation.terms.filter { abs($0.value) > 1e-12 }
            system.lines.append(.text("(\(label())) \(control.plain), som styrer \(part.component.name), er strømmen under \(control.plain)-punktet:"))
            system.lines.append(.math("\(control.latex) = \(symbolic.isEmpty ? "0" : joined(symbolic))"))
            if !numeric.isEmpty { system.lines.append(.math("\(control.latex) = \(joined(numeric))")) }
            system.lines.append(.text("Samlet efter de ubekendte:"))
            system.lines.append(.math(equation.latex(order: system.unknowns)))
            addMaple("\(control.maple + mapleSuffix) = \(maple.isEmpty ? "0*Unit('A')" : joined(maple))")
            system.equations.append((label(), equation))
        }

        guard system.equations.count == system.unknowns.count else {
            return .failure(.message("Der er ikke lige så mange ligninger som ubekendte. Er hele kredsløbet forbundet?"))
        }
        return .success(system)
    }

    /// Terms with their signs: "a - b + c".
    static func joined(_ terms: [(negative: Bool, body: String)]) -> String {
        terms.enumerated().map { index, term in
            index == 0 ? (term.negative ? "-" : "") + term.body : (term.negative ? " - " : " + ") + term.body
        }.joined()
    }

    /// Node voltages by node, with the reference at 0 V.
    static func values(_ model: WalkModel, _ solved: [String: Double]) -> [Int: Double] {
        var result: [Int: Double] = [model.reference: 0]
        for node in model.nodes {
            if let name = model.nodeName[node] { result[node] = solved[name] ?? 0 }
        }
        return result
    }

    /// The value of what each controlled source depends on, by source id.
    static func controlValues(_ model: WalkModel, nodeValues: [Int: Double], solved: [String: Double]) -> [UUID: Double] {
        model.controls.mapValues { control in
            switch control.kind {
            case .voltage(let plus, let minus): (nodeValues[plus] ?? 0) - (nodeValues[minus] ?? 0)
            case .current: solved[control.latex] ?? 0
            }
        }
    }

    /// The voltage points and currents worked out from the node voltages.
    /// Returns the lines and each target's value (by index into `model.targets`).
    static func targetLines(
        _ model: WalkModel, nodeValues: [Int: Double], value: (WalkPart) -> Double,
        controls: [UUID: Double] = [:], superscript: String = ""
    ) -> (lines: [WalkLine], values: [Int: Double]) {
        var lines: [WalkLine] = []
        var values: [Int: Double] = [:]
        func voltage(_ node: Int?) -> Double? { node.flatMap { nodeValues[$0] } }
        func name(_ node: Int) -> String { node == model.reference ? "0" : model.nodeName[node] ?? "0" }

        for (index, target) in model.targets.enumerated() {
            let title = target.name + superscript
            switch target {
            case .probe(let probe):
                let plus = model.netlist.nodeOf[probe.position]
                if let negativePoint = probe.negative {
                    let minus = model.netlist.nodeOf[negativePoint]
                    guard let a = voltage(plus), let b = voltage(minus), let plus, let minus else {
                        lines.append(.text("\(probe.name) sidder ikke på kredsløbet."))
                        continue
                    }
                    values[index] = a - b
                    lines.append(.math("\(title) = \(name(plus)) - \(name(minus)) = \(WalkFormat.quantity(a, .volt)) - \(WalkFormat.quantityFactor(b, .volt)) = \(WalkFormat.quantity(a - b, .volt))"))
                } else {
                    guard let plus, let a = voltage(plus) else {
                        lines.append(.text("\(probe.name) sidder ikke på kredsløbet."))
                        continue
                    }
                    values[index] = a
                    if name(plus) == target.name {
                        lines.append(.math("\(title) = \(WalkFormat.quantity(a, .volt))"))
                    } else {
                        // Measured from the reference: V_o = V_B - 0.
                        lines.append(.math("\(title) = \(name(plus)) - 0 = \(WalkFormat.quantity(a, .volt)) - 0 = \(WalkFormat.quantity(a, .volt))"))
                    }
                }
            case .arrow(let arrow):
                guard let result = arrowCurrent(arrow, model: model, nodeValues: nodeValues, value: value, controls: controls) else {
                    lines.append(.text("Strømmen \(arrow.name) kan ikke udtrykkes her, fordi ledningen er en del af en løkke af ledninger."))
                    continue
                }
                values[index] = result.value
                lines += result.explanation
                lines.append(.math("\(title) = \(result.symbolic) = \(result.numeric) = \(WalkFormat.quantity(result.value, .ampere))"))
            }
        }
        return (lines, values)
    }

    /// A current arrow's current as a sum of component currents, preferring
    /// the side of its wire without voltage sources (their current isn't
    /// given by the node voltages directly).
    static func arrowCurrent(
        _ arrow: CurrentArrow, model: WalkModel, nodeValues: [Int: Double], value: (WalkPart) -> Double,
        controls: [UUID: Double] = [:]
    ) -> (symbolic: String, numeric: String, value: Double, explanation: [WalkLine])? {
        let sides = [false, true].compactMap { model.netlist.componentCoefficients(for: arrow, in: model.circuit, fromOtherSide: $0) }
        func hasVoltageSource(_ coefficients: [UUID: Double]) -> Bool {
            model.parts.contains { $0.kind.setsVoltage && abs(coefficients[$0.component.id] ?? 0) > 1e-9 }
        }
        guard let coefficients = sides.first(where: { !hasVoltageSource($0) }) ?? sides.first else { return nil }

        var symbolic: [(Bool, String)] = []
        var numeric: [(Bool, String)] = []
        var total = 0.0
        var explanation: [WalkLine] = []
        for part in model.parts {
            let coefficient = coefficients[part.component.id] ?? 0
            guard abs(coefficient) > 1e-9 else { continue }
            let negative = coefficient < 0
            guard let current = componentCurrent(part, model: model, nodeValues: nodeValues, value: value, controls: controls) else { return nil }
            total += coefficient * current.value
            symbolic.append((negative, current.symbolic))
            numeric.append((negative, current.numeric))
            explanation += current.explanation
        }
        if symbolic.isEmpty {
            return ("0", "0", 0, [])
        }
        return (joined(symbolic), joined(numeric), total, explanation)
    }

    /// A component's current from its start to its end terminal.
    static func componentCurrent(
        _ part: WalkPart, model: WalkModel, nodeValues: [Int: Double], value: (WalkPart) -> Double,
        controls: [UUID: Double] = [:]
    ) -> (symbolic: String, numeric: String, value: Double, explanation: [WalkLine])? {
        func name(_ node: Int) -> String { node == model.reference ? "0" : model.nodeName[node] ?? "0" }
        switch part.component.kind {
        case .resistor:
            let a = nodeValues[part.start] ?? 0, b = nodeValues[part.end] ?? 0
            let r = value(part)
            return (
                "\\frac{\(name(part.start)) - \(name(part.end))}{\(part.symbol)}",
                "\\frac{\(WalkFormat.factor(a)) - \(WalkFormat.factor(b))}{\(WalkFormat.number(r))}",
                (a - b) / r, []
            )
        case .currentSource:
            let j = value(part)
            return (part.symbol, WalkFormat.factor(j), j, [])
        case .vccs, .cccs:
            let gain = value(part)
            guard let control = model.controls[part.component.id] else { return nil }
            let c = controls[part.component.id] ?? 0
            return ("\(part.valueSymbol) \\cdot \(control.latex)", "\(WalkFormat.number(gain)) \\cdot \(WalkFormat.factor(c))", gain * c, [])
        case .voltageSource, .vcvs, .ccvs:
            // Kirchhoff's current law in a node where it's the only voltage source.
            for node in [part.start, part.end] {
                let others = model.parts.filter {
                    $0.component.id != part.component.id && ($0.start == node) != ($0.end == node)
                }
                guard !others.contains(where: { $0.kind.setsVoltage }) else { continue }
                // The source's current leaves the node at its start terminal, so
                // it's minus (at the start) or plus (at the end) what flows out
                // of the node through the other components.
                var current = 0.0
                var symbolic: [(Bool, String)] = []
                var numeric: [(Bool, String)] = []
                for other in others {
                    guard let otherCurrent = componentCurrent(other, model: model, nodeValues: nodeValues, value: value, controls: controls) else { return nil }
                    let leaving = other.start == node
                    let positive = leaving != (node == part.start)
                    current += positive ? otherCurrent.value : -otherCurrent.value
                    symbolic.append((!positive, otherCurrent.symbolic))
                    numeric.append((!positive, otherCurrent.numeric))
                }
                let symbol = "I_{\(part.component.name)}"
                let explanation: [WalkLine] = [
                    .text("Strømmen gennem \(part.component.name) findes med strømloven i knude \(WalkFormat.plain(name(node))): det, der løber ud gennem de andre komponenter, løber ind gennem kilden."),
                    .math(symbolic.isEmpty
                        ? "\(symbol) = 0"
                        : "\(symbol) = \(joined(symbolic)) = \(joined(numeric)) = \(WalkFormat.number(current))"),
                ]
                return (symbol, WalkFormat.factor(current), current, explanation)
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: Maple

    /// A target in Maple from the node voltages (named with `suffix`), like
    /// `targetLines` works it out. `nil` if it can't be written.
    static func mapleTarget(_ target: WalkTarget, model: WalkModel, value: (WalkPart) -> Double, suffix: String) -> String? {
        func voltage(_ node: Int) -> String {
            node == model.reference ? "0*Unit('V')" : mapleNode(node, model, suffix: suffix)
        }
        switch target {
        case .probe(let probe):
            guard let plus = model.netlist.nodeOf[probe.position] else { return nil }
            guard let negativePoint = probe.negative else { return voltage(plus) }
            guard let minus = model.netlist.nodeOf[negativePoint] else { return nil }
            return "\(voltage(plus)) - \(voltage(minus))"
        case .arrow(let arrow):
            let sides = [false, true].compactMap { model.netlist.componentCoefficients(for: arrow, in: model.circuit, fromOtherSide: $0) }
            func hasVoltageSource(_ coefficients: [UUID: Double]) -> Bool {
                model.parts.contains { $0.kind.setsVoltage && abs(coefficients[$0.component.id] ?? 0) > 1e-9 }
            }
            guard let coefficients = sides.first(where: { !hasVoltageSource($0) }) ?? sides.first else { return nil }
            var terms: [(Bool, String)] = []
            for part in model.parts {
                let coefficient = coefficients[part.component.id] ?? 0
                guard abs(coefficient) > 1e-9 else { continue }
                guard let current = mapleCurrent(part, model: model, value: value, suffix: suffix) else { return nil }
                terms.append((coefficient < 0, current))
            }
            return terms.isEmpty ? "0*Unit('A')" : joined(terms)
        }
    }

    /// A component's current from its start to its end terminal in Maple,
    /// like `componentCurrent`.
    static func mapleCurrent(_ part: WalkPart, model: WalkModel, value: (WalkPart) -> Double, suffix: String) -> String? {
        switch part.component.kind {
        case .resistor:
            let a = mapleNode(part.start, model, suffix: suffix), b = mapleNode(part.end, model, suffix: suffix)
            return "(\(a) - \(b))/\(part.mapleName)"
        case .currentSource, .vccs, .cccs:
            return linearCurrent(part, model, value: value, suffix: suffix)?.maple
        case .voltageSource, .vcvs, .ccvs:
            // Kirchhoff's current law in a node where it's the only voltage source.
            for node in [part.start, part.end] {
                let others = model.parts.filter {
                    $0.component.id != part.component.id && ($0.start == node) != ($0.end == node)
                }
                guard !others.contains(where: { $0.kind.setsVoltage }) else { continue }
                var terms: [(Bool, String)] = []
                for other in others {
                    guard let current = mapleCurrent(other, model: model, value: value, suffix: suffix) else { return nil }
                    let positive = (other.start == node) != (node == part.start)
                    terms.append((!positive, current))
                }
                return terms.isEmpty ? "0*Unit('A')" : "(\(joined(terms)))"
            }
            return nil
        default:
            return nil
        }
    }
}

/// Superposition: one independent source at a time (voltage sources shorted,
/// current sources opened), each solved with the node-voltage method, and
/// the contributions added.
nonisolated enum SuperpositionWalkthrough {
    static func make(_ model: WalkModel) -> WalkResult {
        let sources = model.sources
        guard sources.count >= 2 else {
            return .unavailable("Superposition kræver mindst to uafhængige kilder – kredsløbet har kun \(sources.first?.component.name ?? "én").")
        }
        var sections: [WalkSection] = [WalkSection(title: "1. Opsætning", lines: [
            .text("Kredsløbet er lineært med \(sources.count) uafhængige kilder: \(sources.map(\.component.name).joined(separator: ", ")). Hver kilde regnes for sig, mens de andre slås fra: spændingskilder kortsluttes (0 V), strømkilder afbrydes (0 A). Til sidst lægges bidragene sammen."
                + (model.parts.contains { $0.kind.isDependent } ? " Styrede kilder slås aldrig fra – de er med i hvert delkredsløb." : "")),
            NodalWalkthrough.referenceLine(model),
        ] + model.knownValueLines())]

        var contributions: [[Int: Double]] = []
        // In Maple each source's circuit gets its own names: V_A_1, L1_1, sol_1, IR2_1.
        var maple: [String] = []
        var mapleContributions: [[Int: String]] = []
        for (number, active) in sources.enumerated() {
            let superscript = "^{(\(number + 1))}"
            let suffix = "_\(number + 1)"
            // Controlled sources stay on; they aren't sources of their own.
            let value: (WalkPart) -> Double = { part in
                !part.isIndependent || part.component.id == active.component.id ? part.value : 0
            }
            let off = sources.filter { $0.component.id != active.component.id }.map { source in
                "\(source.component.name) \(source.component.kind == .voltageSource ? "kortsluttes" : "afbrydes")"
            }
            var lines: [WalkLine] = [.text("Kun \(active.component.name) er aktiv; \(off.joined(separator: ", ")).")]
            let system: NodalWalkthrough.System
            switch NodalWalkthrough.equations(model, value: value, mapleSuffix: suffix) {
            case .failure(let error): return .unavailable(error.text)
            case .success(let result): system = result
            }
            lines += system.lines
            guard let solution = Substitution.solve(system.equations, unknowns: system.unknowns) else {
                return .unavailable("Delkredsløbet med kun \(active.component.name) har ikke én løsning.")
            }
            lines.append(.text("Løsning ved gradvis substitution:"))
            lines += solution.lines
            let nodeValues = NodalWalkthrough.values(model, solution.values)
            let controls = NodalWalkthrough.controlValues(model, nodeValues: nodeValues, solved: solution.values)
            let targets = NodalWalkthrough.targetLines(model, nodeValues: nodeValues, value: value, controls: controls, superscript: superscript)
            lines.append(.text("Bidrag fra \(active.component.name):"))
            lines += targets.lines
            contributions.append(targets.values)
            sections.append(WalkSection(title: "\(number + 2). Kun \(active.component.name)", lines: lines))

            let mapleUnknowns = system.mapleUnknowns
            maple += ["", "# Kun \(active.component.name) er aktiv; \(off.joined(separator: ", "))"] + system.maple
            maple.append("sol\(suffix) := solve({\(system.mapleLabels.joined(separator: ", "))}, {\(mapleUnknowns.joined(separator: ", "))}):")
            var parts: [Int: String] = [:]
            for (index, target) in model.targets.enumerated() {
                guard let expression = NodalWalkthrough.mapleTarget(target, model: model, value: value, suffix: suffix) else { continue }
                let name = target.mapleName + suffix
                maple.append("\(name) := eval(\(expression), sol\(suffix)):")
                parts[index] = name
            }
            mapleContributions.append(parts)
        }

        var sum: [WalkLine] = [.text("Bidragene lægges sammen:")]
        maple += ["", "# Bidragene lægges sammen"]
        for (index, target) in model.targets.enumerated() {
            let parts = contributions.map { $0[index] }
            guard parts.allSatisfy({ $0 != nil }) else { continue }
            let values = parts.compactMap { $0 }
            let names = (1...values.count).map { "\(target.name)^{(\($0))}" }.joined(separator: " + ")
            let numbers = values.map(WalkFormat.factor).joined(separator: " + ")
            sum.append(.math("\(target.name) = \(names) = \(numbers) = \(WalkFormat.quantity(values.reduce(0, +), target.unit))"))
            let mapleParts = mapleContributions.compactMap { $0[index] }
            if mapleParts.count == mapleContributions.count {
                maple.append(WalkModel.mapleResult(target, mapleParts.joined(separator: " + "), value: values.reduce(0, +)))
            }
        }
        sections.append(WalkSection(title: "\(sources.count + 2). Resultat", lines: sum))
        return .steps(sections, maple: (model.mapleHeader() + maple).joined(separator: "\n"))
    }
}
