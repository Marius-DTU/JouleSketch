import CoreGraphics
import Foundation

/// The mesh-current method: a current around each window of the drawing,
/// Kirchhoff's voltage law around each mesh, solved by gradual substitution.
/// The meshes are read off the drawing, so it must be planar.
nonisolated enum MeshWalkthrough {
    /// A straight piece of the drawing: a wire piece or a component.
    private struct Edge {
        let a: GridPoint
        let b: GridPoint
        /// The component, or `nil` for a wire.
        let part: WalkPart?
        /// The wire piece's index in the netlist's edges.
        let netlistIndex: Int?
    }

    // swiftlint:disable:next function_body_length
    static func make(_ model: WalkModel) -> WalkResult {
        let groundNodes = Set(model.circuit.grounds.compactMap { model.netlist.nodeOf[$0.position] })
        if groundNodes.count > 1 {
            return .unavailable("Flere stel-symboler forbinder kredsløbet usynligt, så maskerne kan ikke aflæses af tegningen.")
        }

        var edges: [Edge] = []
        for (index, edge) in model.netlist.edges.enumerated() where edge.wireID != nil && edge.a != edge.b {
            edges.append(Edge(a: edge.a, b: edge.b, part: nil, netlistIndex: index))
        }
        for part in model.parts where part.component.start != part.component.end {
            edges.append(Edge(a: part.component.start, b: part.component.end, part: part, netlistIndex: nil))
        }
        for i in edges.indices {
            for j in edges.indices where j > i && cross(edges[i], edges[j]) {
                return .unavailable("Ledninger eller komponenter krydser hinanden uden at være forbundet, så kredsløbet er ikke tegnet plant. Maskemetoden kræver et plant kredsløb – prøv knudepunktsmetoden.")
            }
        }

        // Half-edges: 2i runs a → b, 2i + 1 runs b → a.
        func from(_ h: Int) -> GridPoint { h % 2 == 0 ? edges[h / 2].a : edges[h / 2].b }
        func to(_ h: Int) -> GridPoint { h % 2 == 0 ? edges[h / 2].b : edges[h / 2].a }
        var outgoing: [GridPoint: [Int]] = [:]
        for h in 0..<(edges.count * 2) { outgoing[from(h), default: []].append(h) }
        for (vertex, list) in outgoing {
            outgoing[vertex] = list.sorted { angle($0, from, to) < angle($1, from, to) }
        }
        func next(_ h: Int) -> Int {
            let list = outgoing[to(h)] ?? []
            let index = list.firstIndex(of: h ^ 1) ?? 0
            return list[(index + 1) % list.count]
        }

        // Faces of the drawing.
        var visited = Set<Int>()
        var faces: [[Int]] = []
        for start in 0..<(edges.count * 2) where !visited.contains(start) {
            var face: [Int] = []
            var h = start
            repeat {
                visited.insert(h)
                face.append(h)
                h = next(h)
            } while h != start && face.count <= edges.count * 2
            faces.append(face)
        }
        func area(_ face: [Int]) -> Double {
            face.reduce(0.0) { sum, h in
                let p = from(h), q = to(h)
                return sum + Double(p.x * q.y - q.x * p.y)
            } / 2
        }

        // Each connected piece has one outer face (the largest); the others
        // are the meshes, turned to run clockwise on screen.
        var parent: [GridPoint: GridPoint] = [:]
        func find(_ p: GridPoint) -> GridPoint {
            var root = p
            while let next = parent[root], next != root { root = next }
            return root
        }
        for edge in edges where find(edge.a) != find(edge.b) { parent[find(edge.a)] = find(edge.b) }
        var meshes: [[Int]] = []
        for (_, pieceFaces) in Dictionary(grouping: faces, by: { find(from($0[0])) }) {
            guard let outer = pieceFaces.max(by: { abs(area($0)) < abs(area($1)) }) else { continue }
            for face in pieceFaces where face != outer && abs(area(face)) > 1e-9 {
                meshes.append(area(face) > 0 ? face : face.reversed().map { $0 ^ 1 })
            }
        }
        guard !meshes.isEmpty else {
            return .unavailable("Kredsløbet har ingen lukkede sløjfer, så der er ingen masker.")
        }
        func centroid(_ face: [Int]) -> (Double, Double) {
            let points = face.map(from)
            // Column by column from the left, then top to bottom.
            return (Double(points.map(\.x).reduce(0, +)) / Double(points.count), Double(points.map(\.y).reduce(0, +)) / Double(points.count))
        }
        meshes.sort { centroid($0) < centroid($1) }
        var faceOf: [Int: Int] = [:]
        for (index, mesh) in meshes.enumerated() {
            for h in mesh { faceOf[h] = index }
        }
        // Mesh current arrows on the sheet give their mesh a name and direction.
        var markerOf: [Int: MeshMarker] = [:]
        for marker in model.circuit.meshMarkers {
            let point = CGPoint(x: Double(marker.position.x), y: Double(marker.position.y))
            if let f = meshes.indices.first(where: { markerOf[$0] == nil && contains(meshes[$0].map(from), point) }) {
                markerOf[f] = marker
            }
        }
        /// +1 for a mesh current running clockwise, −1 for counterclockwise.
        let direction: [Double] = meshes.indices.map { markerOf[$0].map { $0.clockwise ? 1 : -1 } ?? 1 }

        // The other meshes get I_{A}, I_{B}, … with letters no other name uses.
        let taken = Set((model.circuit.components.map(\.name) + model.circuit.probes.map(\.name)
            + model.circuit.currents.map(\.name) + model.circuit.meshMarkers.map(\.name)).map(FormulaParts.key)
            + model.controls.values.map(\.plain))
        var freeLetters = WalkFormat.letters.filter { !taken.contains("I" + $0) }.makeIterator()
        var names: [String] = []
        var plainNames: [String] = []
        var mapleNames: [String] = []
        for f in meshes.indices {
            if let marker = markerOf[f] {
                names.append(WalkFormat.name(marker.name))
                plainNames.append(FormulaParts.key(marker.name))
                mapleNames.append(MapleExporter.name(marker.name))
            } else {
                let letter = freeLetters.next() ?? "\(f + 1)"
                names.append("I_{\(letter)}")
                plainNames.append("I\(letter)")
                mapleNames.append("i__\(letter)")
            }
        }

        /// The current along a half-edge from the meshes on each side of it,
        /// each counted in its own direction.
        func along(_ h: Int) -> (text: String, terms: [String: Double]) {
            var terms: [String: Double] = [:]
            for (face, sign) in sides(h) {
                if let face { terms[names[face], default: 0] += sign }
            }
            return (render(sides(h)) { names[$0] }, terms.filter { $0.value != 0 })
        }
        /// The mesh on each side of a half-edge and how its current counts
        /// along it; `own` goes first. `nil` is outside the circuit.
        func sides(_ h: Int, own: Int? = nil) -> [(face: Int?, sign: Double)] {
            var items: [(face: Int?, sign: Double)] = [
                (faceOf[h], faceOf[h].map { direction[$0] } ?? 1),
                (faceOf[h ^ 1], -(faceOf[h ^ 1].map { direction[$0] } ?? 1)),
            ]
            if let own {
                if items[1].face == own { items.swapAt(0, 1) }
            } else if items[1].face != nil, items[1].sign > 0, items[0].face == nil || items[0].sign < 0 {
                // A mesh running along comes first: "I_{B} - 0" rather than "0 + I_{B}".
                items.swapAt(0, 1)
            }
            return items
        }
        /// "I_{C} - I_{B}", "I_{C} - 0", "0 - I_{B}", "-I_{A} + I_{B}".
        func render(_ items: [(face: Int?, sign: Double)], _ term: (Int) -> String) -> String {
            let first = items[0].face.map { (items[0].sign < 0 ? "-" : "") + term($0) } ?? "0"
            guard let other = items[1].face else { return "\(first) - 0" }
            return "\(first) \(items[1].sign < 0 ? "-" : "+") \(term(other))"
        }
        func alongText(_ h: Int, own: Int) -> String {
            render(sides(h, own: own)) { names[$0] }
        }
        /// The same current in Maple: "I_C - I_B".
        func alongMaple(_ h: Int, own: Int? = nil) -> String {
            render(sides(h, own: own)) { mapleNames[$0] }
        }
        var maple: [String] = ["", "# Maskeligninger: strømkilder og KVL rundt i maskerne"]

        // What the controlled sources depend on is an unknown of its own,
        // with its own equation in the mesh currents (step 4).
        var controlled: [(part: WalkPart, control: WalkControl)] = []
        for part in model.parts where part.kind.isDependent {
            guard let control = model.controls[part.component.id] else {
                return .unavailable("\(part.component.name) mangler sin styring.")
            }
            if !controlled.contains(where: { $0.control.latex == control.latex }) {
                controlled.append((part, control))
            }
        }
        let unknowns = names + controlled.map(\.control.latex)

        /// The current under a controlled source's Is point, in mesh currents.
        func controlCurrent(_ part: WalkPart, _ coefficients: [UUID: Double]) -> (text: String, maple: String, terms: [String: Double])? {
            if let marker = model.circuit.sense(of: part.component.id, .current),
               let arrow = model.circuit.currentArrow(for: marker),
               let h = halfEdge(under: arrow, model: model, edges: edges) {
                let current = along(h)
                return (current.text, alongMaple(h), current.terms)
            }
            // Otherwise from the currents of the components it's made of.
            var text: [(Bool, String)] = []
            var mapleTerms: [(Bool, String)] = []
            var terms: [String: Double] = [:]
            for (index, edge) in edges.enumerated() {
                guard let id = edge.part?.component.id, let k = coefficients[id], abs(k) > 1e-9 else { continue }
                let current = along(2 * index)
                text.append((k < 0, "(\(current.text))"))
                mapleTerms.append((k < 0, "(\(alongMaple(2 * index)))"))
                for (name, c) in current.terms { terms[name, default: 0] += k * c }
            }
            guard !text.isEmpty else { return nil }
            return (NodalWalkthrough.joined(text), NodalWalkthrough.joined(mapleTerms), terms.filter { abs($0.value) > 1e-12 })
        }

        /// The voltage from node `minus` to node `plus` by KVL along a path of
        /// the drawing (not through current sources), linear in the unknowns.
        struct Rise {
            var symbolic: [(Bool, String)] = []
            var maple: [(Bool, String)] = []
            var terms: [String: Double] = [:]
            var constant = 0.0
        }
        func rise(from minus: Int, to plus: Int) -> Rise? {
            let starts = Set(outgoing.keys.filter { model.netlist.nodeOf[$0] == minus })
            let targets = Set(outgoing.keys.filter { model.netlist.nodeOf[$0] == plus })
            guard let path = path(from: starts, to: targets, edges: edges, outgoing: outgoing, from: from, to: to) else { return nil }
            var result = Rise()
            for h in path {
                guard let part = edges[h / 2].part else { continue }
                let rising = from(h) == part.component.start
                switch part.kind {
                case .resistor:
                    // + at the end ahead: the current against the walk.
                    let back = along(h ^ 1)
                    result.symbolic.append((false, "\(part.symbol)(\(back.text))"))
                    result.maple.append((false, "\(part.mapleName)*(\(alongMaple(h ^ 1)))"))
                    for (name, c) in back.terms { result.terms[name, default: 0] += part.value * c }
                case .voltageSource:
                    result.symbolic.append((!rising, part.symbol))
                    result.maple.append((!rising, part.mapleName))
                    result.constant += rising ? part.value : -part.value
                case .vcvs, .ccvs:
                    guard let control = model.controls[part.component.id] else { return nil }
                    result.symbolic.append((!rising, "\(part.valueSymbol) \\cdot \(control.latex)"))
                    result.maple.append((!rising, "\(part.mapleName)*\(control.maple)"))
                    result.terms[control.latex, default: 0] += rising ? part.value : -part.value
                default:
                    continue
                }
            }
            return result
        }

        // 1: a loop in every mesh.
        var setup: [WalkLine] = [.text(markerOf.isEmpty
            ? "1: Der tegnes en sløjfe med uret i hver maske, og maskestrømmene navngives:"
            : "1: En sløjfe i hver maske med navn og retning fra maskestrøm-pilene (masker uden pil løber med uret):")]
        for (index, mesh) in meshes.enumerated() {
            let parts = mesh.compactMap { edges[$0 / 2].part?.component.name }
            let turn = direction[index] > 0 ? "med uret" : "mod uret"
            setup.append(.text("\(plainNames[index]) (\(turn)):"))
            setup.append(.math(parts.map(WalkFormat.name).joined(separator: ",\\; ")))
        }
        setup.append(.text("Strømmen i en komponent er maskestrømmen i sløjfens retning minus maskestrømmen på den anden side (0 uden for kredsløbet): I_x = I_A − I_B."))
        setup += model.knownValueLines()

        // 2: an equation for every current source.
        var equationLines: [WalkLine] = []
        var equations: [(label: String, equation: LinearEquation)] = []
        func label() -> String { "L\(equations.count + 1)" }
        var groupParent = Array(meshes.indices)
        func group(_ f: Int) -> Int {
            var root = f
            while groupParent[root] != root { root = groupParent[root] }
            return root
        }
        var constraintsInGroup: [Int: Int] = [:]
        var constraints: [(group: Int, text: String, math: String, maple: String, equation: LinearEquation)] = []
        for (index, edge) in edges.enumerated() {
            guard let part = edge.part, part.kind.setsCurrent else { continue }
            let h = 2 * index  // start → end, the source's direction
            let f = faceOf[h], g = faceOf[h ^ 1]
            let kind = part.kind.isDependent ? "Den styrede strømkilde" : "Strømkilden"
            if f == nil && g == nil || f == g {
                return .unavailable("\(kind) \(part.component.name) ligger ikke mellem to masker.")
            }
            let current = along(h)
            var equation = LinearEquation(terms: current.terms, constant: 0)
            let math: String
            let mapleValue: String
            if part.kind.isDependent, let control = model.controls[part.component.id] {
                // I = gain · control, with the control as an unknown.
                equation.add(control.latex, -part.value)
                math = "\(current.text) = \(part.valueSymbol) \\cdot \(control.latex) = \(WalkFormat.number(part.value)) \\cdot \(control.latex)"
                mapleValue = "\(part.mapleName)*\(control.maple)"
            } else {
                equation.constant = part.value
                math = "\(current.text) = \(WalkFormat.quantity(part.value, .ampere))"
                mapleValue = part.mapleName
            }
            equation.terms = equation.terms.filter { abs($0.value) > 1e-12 }
            let text = f != nil && g != nil
                ? "\(kind) \(part.component.name) sidder mellem \(plainNames[f!]) og \(plainNames[g!]):"
                : "\(kind) \(part.component.name) sidder i \(plainNames[(f ?? g)!]) og på kanten af kredsløbet:"
            if let f, let g { groupParent[group(f)] = group(g) }
            constraints.append((group((f ?? g)!), text, math, "\(alongMaple(h)) = \(mapleValue)", equation))
        }
        if !constraints.isEmpty {
            equationLines.append(.text("2: For hver strømkilde: maskestrømmen i kildens retning minus den modsatte er lig med kildens strøm."
                + (constraints.contains { $0.text.hasPrefix("Den styrede") } ? " En styret strømkilde giver faktoren gange styrestørrelsen." : "")))
        }
        for constraint in constraints {
            constraintsInGroup[group(constraint.group), default: 0] += 1
            equationLines.append(.text("\(label()): \(constraint.text)"))
            equationLines.append(.math(constraint.math))
            maple.append("\(label()) := \(constraint.maple):")
            equations.append((label(), constraint.equation))
        }

        // 3: KVL around every mesh without a current source; a current source
        // between two meshes gives one common equation around the source.
        struct Loop {
            var symbolic: [(Bool, String)] = []
            var numeric: [(Bool, String)] = []
            var maple: [(Bool, String)] = []
            var equation = LinearEquation()
        }
        func loop(_ f: Int) -> Loop {
            var result = Loop()
            // Round the mesh in its own direction.
            let walk = direction[f] > 0 ? meshes[f] : meshes[f].reversed().map { $0 ^ 1 }
            for h in walk {
                guard let part = edges[h / 2].part, faceOf[h] != faceOf[h ^ 1] else { continue }
                switch part.component.kind {
                case .resistor:
                    let current = along(h)
                    let text = alongText(h, own: f)
                    result.symbolic.append((false, "\(part.symbol)(\(text))"))
                    result.numeric.append((false, "\(WalkFormat.quantity(part.value, .ohm))(\(text))"))
                    result.maple.append((false, "\(part.mapleName)*(\(alongMaple(h, own: f)))"))
                    for (name, sign) in current.terms { result.equation.add(name, sign * part.value) }
                case .voltageSource:
                    // Going from − to + the voltage rises, so it counts negative.
                    let rising = from(h) == part.component.start
                    result.symbolic.append((rising, part.symbol))
                    result.numeric.append((rising, WalkFormat.quantity(part.value, .volt)))
                    result.maple.append((rising, part.mapleName))
                    result.equation.constant += rising ? part.value : -part.value
                case .vcvs, .ccvs:
                    // A controlled voltage source counts like one, with gain ·
                    // control in place of its voltage; the control is an unknown.
                    guard let control = model.controls[part.component.id] else { continue }
                    let rising = from(h) == part.component.start
                    result.symbolic.append((rising, "\(part.valueSymbol) \\cdot \(control.latex)"))
                    result.numeric.append((rising, "\(WalkFormat.factor(part.value)) \\cdot \(control.latex)"))
                    result.maple.append((rising, "\(part.mapleName)*\(control.maple)"))
                    result.equation.add(control.latex, rising ? -part.value : part.value)
                default:
                    continue
                }
            }
            return result
        }
        let groups = Dictionary(grouping: meshes.indices, by: group)
        var firstLoop = true
        for root in groups.keys.sorted() {
            let members = (groups[root] ?? []).sorted()
            let needed = members.count - (constraintsInGroup[root] ?? 0)
            guard needed == 0 || needed == 1 else {
                return .unavailable("Strømkilderne kan ikke fordeles på maskerne, så maskemetoden kan ikke bruges her.")
            }
            guard needed == 1 else { continue }
            if firstLoop {
                equationLines.append(.text("3: KVL rundt i hver maske uden strømkilde: summen af spændingerne er 0. Over en modstand R(I_egen − I_anden); en spændingskilde tæller negativt, når man går fra − til +."))
                firstLoop = false
            }
            var total = Loop()
            for f in members {
                let part = loop(f)
                total.symbolic += part.symbolic
                total.numeric += part.numeric
                total.maple += part.maple
                for (name, coefficient) in part.equation.terms { total.equation.add(name, coefficient) }
                total.equation.constant += part.equation.constant
            }
            total.equation.terms = total.equation.terms.filter { abs($0.value) > 1e-12 }
            let around = members.count == 1
                ? "maske \(plainNames[members[0]])"
                : "én fælles ligning uden om strømkilden (\(members.map { plainNames[$0] }.joined(separator: " og ")))"
            equationLines.append(.text("\(label()): KVL i \(around):"))
            equationLines.append(.math("\(total.symbolic.isEmpty ? "0" : NodalWalkthrough.joined(total.symbolic)) = 0"))
            equationLines.append(.math("\(total.numeric.isEmpty ? "0" : NodalWalkthrough.joined(total.numeric)) = 0"))
            maple.append("\(label()) := \(total.maple.isEmpty ? "0" : NodalWalkthrough.joined(total.maple)) = 0:")
            // Divided by the resistance in front of the mesh's own current, the
            // equation is in amperes: that current alone, the source side a current.
            let own = names[members[0]]
            if let resistance = total.equation.terms[own], resistance > 1e-12 {
                var inCurrent = total.equation
                inCurrent.terms = inCurrent.terms.mapValues { $0 / resistance }
                inCurrent.constant /= resistance
                equationLines.append(.text("Samlet og divideret med \(WalkFormat.number(resistance)) Ω, så ligningen står i strøm (A):"))
                equationLines.append(.math(inCurrent.latex(order: unknowns)))
                equations.append((label(), inCurrent))
            } else {
                equationLines.append(.math(total.equation.latex(order: unknowns)))
                equations.append((label(), total.equation))
            }
        }

        // 4: what the controlled sources depend on, written with the mesh currents.
        if !controlled.isEmpty {
            equationLines.append(.text("4: For hver styret kilde: styrestrømmen eller styrespændingen udtrykt ved maskestrømmene. En strøm er I_A − I_B; en spænding findes med KVL fra − til + over modstande R(I_A − I_B)."))
        }
        for (part, control) in controlled {
            var equation = LinearEquation()
            equation.add(control.latex, 1)
            let symbolic: String
            let mapleExpression: String
            switch control.kind {
            case .current(let coefficients):
                guard let expression = controlCurrent(part, coefficients) else {
                    return .unavailable("\(control.plain) for \(part.component.name) kan ikke findes på tegningen. Flyt \(control.plain)-punktet.")
                }
                symbolic = expression.text
                mapleExpression = expression.maple
                for (name, c) in expression.terms { equation.add(name, -c) }
                equationLines.append(.text("\(label()): \(control.plain), som styrer \(part.component.name), er strømmen under \(control.plain)-punktet:"))
            case .voltage(let plus, let minus):
                guard let expression = rise(from: minus, to: plus) else {
                    return .unavailable("\(control.plain) for \(part.component.name) kan ikke findes uden at gå gennem en strømkilde.")
                }
                symbolic = expression.symbolic.isEmpty ? "0" : NodalWalkthrough.joined(expression.symbolic)
                mapleExpression = expression.maple.isEmpty ? "0*Unit('V')" : NodalWalkthrough.joined(expression.maple)
                for (name, c) in expression.terms { equation.add(name, -c) }
                equation.constant = expression.constant
                equationLines.append(.text("\(label()): \(control.plain), som styrer \(part.component.name), er spændingen fra − til + (KVL langs vejen):"))
            }
            equation.terms = equation.terms.filter { abs($0.value) > 1e-12 }
            equationLines.append(.math("\(control.latex) = \(symbolic)"))
            equationLines.append(.text("Samlet efter de ubekendte:"))
            equationLines.append(.math(equation.latex(order: unknowns)))
            maple.append("\(label()) := \(control.maple) = \(mapleExpression):")
            equations.append((label(), equation))
        }

        guard equations.count == unknowns.count,
              let solution = Substitution.solve(equations, unknowns: unknowns) else {
            return .unavailable("Maskeligningerne har ikke én løsning.")
        }
        func current(_ name: String) -> Double { solution.values[name] ?? 0 }
        func value(_ h: Int) -> Double {
            along(h).terms.reduce(0) { $0 + $1.value * current($1.key) }
        }
        /// "4 [[mA]] - 0,25 [[mA]]" for a half-edge, like its `along` text.
        func numbers(_ h: Int) -> String {
            render(sides(h)) { WalkFormat.quantityFactor(current(names[$0]), .ampere) }
        }
        maple += [
            "", "# Løs for maskestrømmene",
            "sol := solve({\(equations.map(\.label).joined(separator: ", "))}, {\((mapleNames + controlled.map(\.control.maple)).joined(separator: ", "))}):",
            "", "# Det, der blev spurgt om",
        ]

        // 6: what was asked for.
        var results: [WalkLine] = [
            .text("5: Maskestrømmene:"),
            .math(names.map { "\($0) = \(WalkFormat.quantity(current($0), .ampere))" }.joined(separator: ";\\quad ")),
        ]
        if !controlled.isEmpty {
            results.append(.text("Styrestørrelserne:"))
            results.append(.math(controlled.map { item in
                let unit: PhysicalUnit = if case .voltage = item.control.kind { .volt } else { .ampere }
                return "\(item.control.latex) = \(WalkFormat.quantity(current(item.control.latex), unit))"
            }.joined(separator: ";\\quad ")))
        }
        results += [
            .text("6: Det, der blev spurgt om. Over en modstand er V_x = R_x(I_A − I_B), med + dér, hvor I_A løber ind; spændinger over strømkilder findes med KVL."),
        ]
        for target in model.targets {
            switch target {
            case .arrow(let arrow):
                guard let h = halfEdge(under: arrow, model: model, edges: edges) else {
                    results.append(.text("Strømmen \(arrow.name) kan ikke findes på tegningen."))
                    continue
                }
                results.append(.math("\(target.name) = \(along(h).text) = \(numbers(h)) = \(WalkFormat.quantity(value(h), .ampere))"))
                maple.append(WalkModel.mapleResult(target, "eval(\(alongMaple(h)), sol)", value: value(h)))
            case .probe(let probe):
                // From the reference (or the − point) to the point: the voltage
                // over each resistor on the way, then KVL along the way.
                let starts: Set<GridPoint> = probe.negative.map { [$0] }
                    ?? Set(outgoing.keys.filter { model.netlist.nodeOf[$0] == model.reference })
                guard let path = path(from: starts, to: [probe.position], edges: edges, outgoing: outgoing, from: from, to: to) else {
                    results.append(.text("\(probe.name) kan ikke findes uden at gå gennem en strømkilde."))
                    continue
                }
                var symbolic: [(Bool, String)] = []
                var numeric: [(Bool, String)] = []
                var mapleTerms: [(Bool, String)] = []
                var total = 0.0
                var resistorLines: [WalkLine] = []
                for h in path {
                    guard let part = edges[h / 2].part else { continue }
                    switch part.component.kind {
                    case .resistor:
                        // + at the end nearer the point: the current against the walk.
                        let back = h ^ 1
                        let v = part.value * value(back)
                        let name = "V_{\(part.component.name)}"
                        resistorLines.append(.math("\(name)(\\pm) = \(part.symbol)(\(along(back).text)) = \(WalkFormat.quantity(part.value, .ohm)) \\cdot (\(numbers(back))) = \(WalkFormat.quantity(v, .volt))"))
                        symbolic.append((false, name))
                        numeric.append((false, WalkFormat.quantityFactor(v, .volt)))
                        mapleTerms.append((false, "\(part.mapleName)*(\(alongMaple(back)))"))
                        total += v
                    case .voltageSource:
                        let rising = from(h) == part.component.start
                        symbolic.append((!rising, part.symbol))
                        numeric.append((!rising, WalkFormat.quantity(part.value, .volt)))
                        mapleTerms.append((!rising, part.mapleName))
                        total += rising ? part.value : -part.value
                    case .vcvs, .ccvs:
                        guard let control = model.controls[part.component.id] else { continue }
                        let rising = from(h) == part.component.start
                        let c = current(control.latex)
                        let e = part.value * c
                        let unit: PhysicalUnit = part.kind == .vcvs ? .volt : .ampere
                        symbolic.append((!rising, "\(part.valueSymbol) \\cdot \(control.latex)"))
                        numeric.append((!rising, "\(WalkFormat.factor(part.value)) \\cdot \(WalkFormat.quantityFactor(c, unit))"))
                        mapleTerms.append((!rising, "\(part.mapleName)*\(control.maple)"))
                        total += rising ? e : -e
                    default:
                        continue
                    }
                }
                let expression = mapleTerms.isEmpty ? "0*Unit('V')" : NodalWalkthrough.joined(mapleTerms)
                maple.append(WalkModel.mapleResult(target, "eval(\(expression), sol)", value: total))
                results += resistorLines
                if symbolic.isEmpty {
                    results.append(.math("\(target.name) = \(WalkFormat.quantity(0, .volt))"))
                } else if symbolic.count == 1, resistorLines.count == 1, !symbolic[0].0 {
                    // Just the voltage over one resistor; say so unless it has the same name.
                    if FormulaParts.key(target.name) != FormulaParts.key(symbolic[0].1) {
                        results.append(.math("\(target.name) = \(symbolic[0].1) = \(WalkFormat.quantity(total, .volt))"))
                    }
                } else {
                    results.append(.text("KVL \(probe.negative == nil ? "fra referencen hen til \(probe.name)" : "fra − til + ved \(probe.name)"):"))
                    results.append(.math("\(target.name) = \(NodalWalkthrough.joined(symbolic)) = \(NodalWalkthrough.joined(numeric)) = \(WalkFormat.quantity(total, .volt))"))
                }
            }
        }

        return .steps([
            WalkSection(title: "1. Opsætning", lines: [NodalWalkthrough.referenceLine(model)] + setup),
            WalkSection(title: "2. Maskeligninger", lines: equationLines),
            WalkSection(title: "3. Løsning ved gradvis substitution", lines: solution.lines),
            WalkSection(title: "4. Resultat", lines: results),
        ], maple: (model.mapleHeader() + maple).joined(separator: "\n"))
    }

    /// The direction of a half-edge, for sorting the half-edges around a point.
    private static func angle(_ h: Int, _ from: (Int) -> GridPoint, _ to: (Int) -> GridPoint) -> Double {
        let a = from(h), b = to(h)
        return atan2(Double(b.y - a.y), Double(b.x - a.x))
    }

    /// Whether two pieces cross or touch somewhere other than a shared end.
    private static func cross(_ e: Edge, _ f: Edge) -> Bool {
        func orientation(_ p: GridPoint, _ q: GridPoint, _ r: GridPoint) -> Int {
            let value = (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
            return value == 0 ? 0 : (value > 0 ? 1 : -1)
        }
        func onSegment(_ p: GridPoint, _ a: GridPoint, _ b: GridPoint) -> Bool {
            orientation(a, b, p) == 0 && min(a.x, b.x) <= p.x && p.x <= max(a.x, b.x) && min(a.y, b.y) <= p.y && p.y <= max(a.y, b.y)
        }
        let shared = Set([e.a, e.b]).intersection([f.a, f.b])
        // An end of one lying inside the other.
        for p in [e.a, e.b] where !shared.contains(p) && onSegment(p, f.a, f.b) { return true }
        for p in [f.a, f.b] where !shared.contains(p) && onSegment(p, e.a, e.b) { return true }
        guard shared.isEmpty else { return false }
        let o1 = orientation(e.a, e.b, f.a), o2 = orientation(e.a, e.b, f.b)
        let o3 = orientation(f.a, f.b, e.a), o4 = orientation(f.a, f.b, e.b)
        return o1 * o2 < 0 && o3 * o4 < 0
    }

    /// The half-edge under a current arrow, pointing the way it points.
    private static func halfEdge(under arrow: CurrentArrow, model: WalkModel, edges: [Edge]) -> Int? {
        guard let placement = model.circuit.placement(of: arrow) else { return nil }
        let point = placement.point, direction = placement.direction
        func contains(_ edge: Edge, _ p: CGPoint) -> Bool {
            p.distance(toSegment: CGPoint(x: edge.a.x, y: edge.a.y), CGPoint(x: edge.b.x, y: edge.b.y)) < 1e-6
        }
        let ahead = CGPoint(x: point.x + direction.x * 0.01, y: point.y + direction.y * 0.01)
        let candidates = edges.indices.filter { index in
            guard let netlistIndex = edges[index].netlistIndex else { return false }
            return model.netlist.edges[netlistIndex].wireID == arrow.wireID && contains(edges[index], point)
        }
        guard let index = candidates.first(where: { contains(edges[$0], ahead) }) ?? candidates.first else { return nil }
        let edge = edges[index]
        let forward = direction.x * Double(edge.b.x - edge.a.x) + direction.y * Double(edge.b.y - edge.a.y) >= 0
        return forward ? 2 * index : 2 * index + 1
    }

    /// Half-edges from one of `starts` to one of `targets`, not through
    /// current sources (controlled ones too).
    private static func path(
        from starts: Set<GridPoint>, to targets: Set<GridPoint>, edges: [Edge], outgoing: [GridPoint: [Int]],
        from: (Int) -> GridPoint, to: (Int) -> GridPoint
    ) -> [Int]? {
        guard !starts.isEmpty, !targets.isEmpty else { return nil }
        if !starts.isDisjoint(with: targets) { return [] }
        var cameBy: [GridPoint: Int] = [:]
        var queue = Array(starts)
        var seen = starts
        while !queue.isEmpty {
            let vertex = queue.removeFirst()
            for h in outgoing[vertex] ?? [] {
                if edges[h / 2].part?.kind.setsCurrent == true { continue }
                let next = to(h)
                guard !seen.contains(next) else { continue }
                seen.insert(next)
                cameBy[next] = h
                if targets.contains(next) {
                    var result: [Int] = []
                    var point = next
                    while let h = cameBy[point] {
                        result.insert(h, at: 0)
                        point = from(h)
                    }
                    return result
                }
                queue.append(next)
            }
        }
        return nil
    }
}

private extension MeshWalkthrough {
    /// Whether a point lies inside a polygon (ray casting).
    static func contains(_ polygon: [GridPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            let (ax, ay, bx, by) = (Double(a.x), Double(a.y), Double(b.x), Double(b.y))
            if (ay > point.y) != (by > point.y), point.x < (bx - ax) * (point.y - ay) / (by - ay) + ax {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
