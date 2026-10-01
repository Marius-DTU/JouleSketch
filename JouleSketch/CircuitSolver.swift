import CoreGraphics
import Foundation

/// Values the solver filled in, and what it couldn't work out.
nonisolated struct CircuitSolution {
    /// Computed values for components whose value is unknown.
    var componentValues: [UUID: Double] = [:]
    /// Computed voltages for voltage points whose value is unknown.
    var probeValues: [UUID: Double] = [:]
    /// Computed currents for current arrows whose value is unknown.
    var currentValues: [UUID: Double] = [:]
    /// The power absorbed by components with a power circle, by component id
    /// (P = U·I with U and I in the same direction; negative when delivered).
    var powerValues: [UUID: Double] = [:]
    /// Problems and missing information, for the "Beregning" report.
    var issues: [SolverIssue] = []
    /// `false` when the known values contradict each other.
    var isConsistent = true
    /// How many values were unknown, and how many of them were computed.
    var unknownCount = 0
    var solvedCount = 0
    /// Whether each diode conducts (`true`) or blocks (`false`).
    var diodeConducts: [UUID: Bool] = [:]
    /// Each diode's voltage Vd and current Id, from anode to cathode.
    var diodeValues: [UUID: (voltage: Double, current: Double)] = [:]

    /// The solution without the values it found, for study mode. What's
    /// missing and whether everything can be computed is still there.
    var withoutValues: CircuitSolution {
        var solution = self
        solution.componentValues = [:]
        solution.probeValues = [:]
        solution.currentValues = [:]
        solution.powerValues = [:]
        solution.diodeConducts = [:]
        solution.diodeValues = [:]
        return solution
    }

    /// Whether every unknown value was computed and nothing is missing or contradictory.
    var isComplete: Bool {
        isConsistent && solvedCount == unknownCount && !issues.contains { $0.kind != .notice }
    }
}

nonisolated struct SolverIssue: Identifiable {
    enum Kind {
        /// The known values contradict each other.
        case conflict
        /// A value can't be computed yet.
        case missing
        /// Something the user should know, e.g. there's no ground.
        case notice
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String
}

/// Solves a circuit with Kirchhoff's laws and Ohm's law.
///
/// Every node voltage, every component current and every unknown component
/// value is a variable. The equations are Ohm's law for resistors, the source
/// equations, Kirchhoff's current law in each node, and every value the user
/// has entered. Unknown resistances make the system nonlinear, so it's solved
/// with Levenberg–Marquardt. A quantity counts as computed only if it's
/// uniquely determined, which is checked with the rank of the Jacobian.
///
/// Diodes either conduct, with their forward voltage across them, or block,
/// with no current. Starting with all of them conducting, the circuit is
/// solved and the diode that fits its state worst (a conducting diode with
/// current flowing backwards, or a blocking one with more than its forward
/// voltage across it) is switched, until every diode fits.
nonisolated enum CircuitSolver {
    static func solve(_ circuit: Circuit) -> CircuitSolution {
        let diodes = circuit.components.filter { $0.kind.isDiode }

        /// Solves with the given diodes conducting; also returns the diode
        /// that fits its state worst, if any.
        func attempt(_ conducting: Set<UUID>) -> (solution: CircuitSolution, worst: UUID?) {
            var model = Model(circuit: circuit, conducting: conducting)
            var solution = model.solve()
            for diode in diodes { solution.diodeConducts[diode.id] = conducting.contains(diode.id) }
            return (solution, model.worstDiodeViolation())
        }

        // Switch the worst-fitting diode until all fit.
        var conducting = Set(diodes.map(\.id))
        var tried = Set<Set<UUID>>()
        var first: CircuitSolution?
        for _ in 0..<(4 * diodes.count + 1) {
            guard tried.insert(conducting).inserted else { break }
            let (solution, worst) = attempt(conducting)
            first = first ?? solution
            // Contradicting values may come from a wrong guess; search below.
            guard solution.isConsistent else { break }
            guard let worst else { return solution }
            if conducting.contains(worst) { conducting.remove(worst) } else { conducting.insert(worst) }
        }

        // Otherwise try every combination, with as many conducting as possible first.
        if diodes.count <= 8 {
            let masks = (0..<(1 << diodes.count)).sorted { $0.nonzeroBitCount < $1.nonzeroBitCount }
            for mask in masks {
                let state = Set(diodes.indices.filter { mask & (1 << $0) == 0 }.map { diodes[$0].id })
                guard tried.insert(state).inserted else { continue }
                let (solution, worst) = attempt(state)
                if solution.isConsistent, worst == nil { return solution }
            }
        }

        guard var solution = first else { return CircuitSolution() }
        if solution.isConsistent {
            solution.issues.append(SolverIssue(
                kind: .conflict,
                title: "Dioderne passer ikke sammen",
                detail: "Der er ingen kombination af ledende og spærrende dioder, der passer med resten af kredsløbet. Tjek dioderne og deres retning."
            ))
            solution.isConsistent = false
        }
        return solution
    }
}

/// The value of an equivalent resistance (Req), or why it can't be found.
nonisolated enum EquivalentResult: Equatable {
    /// The resistance, and the resistors carrying current between the two points.
    case value(Double, resistors: Set<UUID>)
    /// One of the points isn't on the circuit.
    case notOnCircuit
    /// No path of resistors joins the two points.
    case notConnected
    /// These resistors have neither a known nor a computed value.
    case unknownValues([String])
    /// Controlled sources or diodes take part, and a control is missing or
    /// there's no single answer.
    case dependentSources([String])

    /// The resistors making up the Req.
    var resistors: Set<UUID> {
        if case .value(_, let resistors) = self { return resistors }
        return []
    }
}

nonisolated extension CircuitSolver {
    /// The resistance seen between two points of the circuit with the
    /// independent sources turned off: voltage sources become a short
    /// circuit and current sources an open circuit. A source connected right
    /// between the two points is removed instead. Uses the known and
    /// computed resistor values. Works by sending 1 A in at `a` and out at
    /// `b`; Req is then the voltage between them, and the resistors
    /// carrying some of that current are the ones Req is made of.
    static func equivalentResistance(
        between pointA: GridPoint, and pointB: GridPoint, in circuit: Circuit, netlist: Netlist, solution: CircuitSolution
    ) -> EquivalentResult {
        guard let nodeA = netlist.node(at: pointA),
              let nodeB = netlist.node(at: pointB) else { return .notOnCircuit }

        // Short circuits (voltage sources and 0 Ω) join their two nodes into one.
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
        func node(_ point: GridPoint) -> Int { netlist.nodeOf[point, default: -1] }

        var resistors: [(id: UUID, name: String, p: Int, q: Int, r: Double?)] = []
        var dependent: [(name: String, p: Int, q: Int)] = []
        var voltageSources: [(p: Int, q: Int)] = []
        for component in circuit.components {
            let p = node(component.start), q = node(component.end)
            switch component.kind {
            case .resistor:
                let r = component.value ?? solution.componentValues[component.id]
                if r == 0 { join(p, q) }
                resistors.append((component.id, component.name, p, q, r))
            case .voltageSource: voltageSources.append((p, q))
            case .currentSource: break
            case .vcvs, .ccvs, .vccs, .cccs, .diode, .led: dependent.append((component.name, p, q))
            }
        }
        // A source sitting right between the two points (also through 0 Ω
        // resistors) is the one Req is seen from, so it's taken out instead
        // of shorted. Decided before any source is shorted.
        let ends = Set([find(nodeA), find(nodeB)])
        let shorted = voltageSources.filter { Set([find($0.p), find($0.q)]) != ends }
        for source in shorted { join(source.p, source.q) }
        let a = find(nodeA)
        let b = find(nodeB)
        if a == b { return .value(0, resistors: []) }

        // Only what lies on some path between a and b matters; branches
        // hanging off a single node carry none of the test current. Those
        // are the edges in the same biconnected block as a virtual edge a–b.
        enum EdgeKind { case resistor(Int), dependent(Int), virtual }
        var edges: [(p: Int, q: Int, kind: EdgeKind)] = [(a, b, .virtual)]
        for (i, resistor) in resistors.enumerated() where find(resistor.p) != find(resistor.q) {
            edges.append((find(resistor.p), find(resistor.q), .resistor(i)))
        }
        for (i, source) in dependent.enumerated() where find(source.p) != find(source.q) {
            edges.append((find(source.p), find(source.q), .dependent(i)))
        }
        var adjacency: [Int: [(edge: Int, to: Int)]] = [:]
        for (i, edge) in edges.enumerated() {
            adjacency[edge.p, default: []].append((i, edge.q))
            adjacency[edge.q, default: []].append((i, edge.p))
        }
        // Tarjan's algorithm for biconnected blocks, keeping the block of edge 0.
        var discovered: [Int: Int] = [:]
        var low: [Int: Int] = [:]
        var edgeStack: [Int] = []
        var block = Set<Int>()
        func visit(_ u: Int, via parentEdge: Int?) {
            let order = discovered.count
            discovered[u] = order
            low[u] = order
            for (edge, v) in adjacency[u] ?? [] where edge != parentEdge {
                if let orderV = discovered[v] {
                    // A back edge (or a parallel edge to the parent).
                    if orderV < order {
                        edgeStack.append(edge)
                        low[u] = min(low[u] ?? order, orderV)
                    }
                } else {
                    edgeStack.append(edge)
                    visit(v, via: edge)
                    low[u] = min(low[u] ?? order, low[v] ?? order)
                    if (low[v] ?? order) >= order {
                        var found = Set<Int>()
                        while let popped = edgeStack.popLast() {
                            found.insert(popped)
                            if popped == edge { break }
                        }
                        if found.contains(0) { block = found }
                    }
                }
            }
        }
        visit(a, via: nil)

        var relevantResistors: [Int] = []
        var relevantDependent: [Int] = []
        for edge in block {
            switch edges[edge].kind {
            case .resistor(let i): relevantResistors.append(i)
            case .dependent(let i): relevantDependent.append(i)
            case .virtual: break
            }
        }
        guard !relevantResistors.isEmpty || !relevantDependent.isEmpty else { return .notConnected }
        let unknown = relevantResistors.sorted().map { resistors[$0] }.filter { $0.r == nil }
        guard unknown.isEmpty else { return .unknownValues(unknown.map(\.name)) }
        if !relevantDependent.isEmpty {
            // Controlled sources or diodes take part: Req = Voc / Isc, found
            // the same way with a 1 A test current and them left in.
            return testCurrentResistance(between: nodeA, and: nodeB, in: circuit, netlist: netlist, solution: solution)
                ?? .dependentSources(Array(Set(relevantDependent.map { dependent[$0].name })).sorted())
        }
        let relevant = relevantResistors.map { resistors[$0] }

        // Nodal analysis with b as reference: G·v = 1 A into a.
        let blockNodes = Set(relevant.flatMap { [find($0.p), find($0.q)] })
        let nodes = blockNodes.subtracting([b]).sorted()
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        var conductance = [[Double]](repeating: [Double](repeating: 0, count: nodes.count), count: nodes.count)
        for resistor in relevant {
            guard let r = resistor.r, r > 0 else { continue }
            // Nodes missing from `index` are the reference b.
            let i = index[find(resistor.p)]
            let j = index[find(resistor.q)]
            guard i != j else { continue }
            let g = 1 / r
            if let i { conductance[i][i] += g }
            if let j { conductance[j][j] += g }
            if let i, let j {
                conductance[i][j] -= g
                conductance[j][i] -= g
            }
        }
        guard let ia = index[a] else { return .notConnected }
        var injected = [Double](repeating: 0, count: nodes.count)
        injected[ia] = 1
        guard let voltages = LinearAlgebra.solve(conductance, injected) else { return .notConnected }
        func voltage(_ n: Int) -> Double { index[find(n)].map { voltages[$0] } ?? 0 }

        // Resistors carrying part of the 1 A test current.
        var used = Set<UUID>()
        for resistor in relevant {
            guard let r = resistor.r, r > 0 else { continue }
            if abs(voltage(resistor.p) - voltage(resistor.q)) / r > 1e-9 { used.insert(resistor.id) }
        }
        // A 0 Ω resistor carries current if it joins parts where current flows.
        for resistor in resistors where resistor.r == 0 && blockNodes.contains(find(resistor.p)) {
            let touchesUsed = resistors.contains { other in
                used.contains(other.id) && [other.p, other.q].contains { find($0) == find(resistor.p) }
            }
            if touchesUsed { used.insert(resistor.id) }
        }
        return .value(voltages[ia], resistors: used)
    }

    /// Req with controlled sources and diodes, by modified nodal analysis:
    /// independent sources off, controlled sources on, diodes in their solved
    /// state without their threshold voltage (conducting is a short, blocking
    /// is open), and 1 A sent in at `nodeA` and out at `nodeB`. Req is the
    /// voltage that gives. `nil` if a control is missing or there's no single
    /// solution.
    private static func testCurrentResistance(
        between nodeA: Int, and nodeB: Int, in circuit: Circuit, netlist: Netlist, solution: CircuitSolution
    ) -> EquivalentResult? {
        func node(_ point: GridPoint) -> Int { netlist.nodeOf[point, default: -1] }
        let ends = Set([nodeA, nodeB])

        // Only the piece of the circuit joined to the two points, through
        // components that aren't open: switched-off current sources, blocking
        // diodes and a voltage source right between the points are.
        func isOpen(_ component: CircuitComponent) -> Bool {
            switch component.kind {
            case .currentSource: true
            case .voltageSource: Set([node(component.start), node(component.end)]) == ends
            case .diode, .led: solution.diodeConducts[component.id] != true
            default: false
            }
        }
        var neighbors: [Int: [Int]] = [:]
        for component in circuit.components where !isOpen(component) {
            let p = node(component.start), q = node(component.end)
            neighbors[p, default: []].append(q)
            neighbors[q, default: []].append(p)
        }
        var piece: Set<Int> = [nodeA]
        var queue = [nodeA]
        while let next = queue.popLast() {
            for neighbor in neighbors[next] ?? [] where !piece.contains(neighbor) {
                piece.insert(neighbor)
                queue.append(neighbor)
            }
        }
        guard piece.contains(nodeB) else { return .notConnected }
        let components = circuit.components.filter { piece.contains(node($0.start)) }

        // Unknowns: node voltages (nodeB is 0 V), the current of each branch
        // that sets a voltage, and each controlling current.
        var index: [Int: Int] = [:]
        for n in piece.sorted() where n != nodeB { index[n] = index.count }
        var count = index.count
        var branch: [UUID: Int] = [:]
        for component in components {
            let setsVoltage: Bool = switch component.kind {
            case .voltageSource:
                // A source right between the two points is taken out.
                Set([node(component.start), node(component.end)]) != ends
            case .vcvs, .ccvs: true
            case .resistor: (component.value ?? solution.componentValues[component.id]) == 0
            case .diode, .led: solution.diodeConducts[component.id] == true
            case .currentSource, .vccs, .cccs: false
            }
            if setsVoltage {
                branch[component.id] = count
                count += 1
            }
        }
        var controlCurrent: [UUID: (unknown: Int, coefficients: [UUID: Double])] = [:]
        for component in components where component.kind.isCurrentControlled {
            guard let arrow = circuit.sense(of: component.id, .current).flatMap({ circuit.currentArrow(for: $0) }),
                  let coefficients = netlist.componentCoefficients(for: arrow, in: circuit) else { return nil }
            controlCurrent[component.id] = (count, coefficients)
            count += 1
        }

        typealias Row = [Int: Double]
        func voltage(_ n: Int) -> Row { index[n].map { [$0: 1] } ?? [:] }
        func difference(_ p: Int, _ q: Int) -> Row { voltage(p).merging(voltage(q).mapValues { -$0 }, uniquingKeysWith: +) }
        func scaled(_ row: Row, _ k: Double) -> Row { row.mapValues { $0 * k } }
        func controlRow(_ component: CircuitComponent) -> Row? {
            if component.kind.isVoltageControlled {
                guard let plus = circuit.sense(of: component.id, .plus).flatMap({ netlist.nodeOf[$0.gridPoint] }),
                      let minus = circuit.sense(of: component.id, .minus).flatMap({ netlist.nodeOf[$0.gridPoint] }) else { return nil }
                return difference(plus, minus)
            }
            return controlCurrent[component.id].map { [$0.unknown: 1] }
        }
        /// A component's current from start to end, linear in the unknowns.
        func current(_ component: CircuitComponent) -> Row? {
            if let unknown = branch[component.id] { return [unknown: 1] }
            let p = node(component.start), q = node(component.end)
            switch component.kind {
            case .resistor:
                guard let r = component.value ?? solution.componentValues[component.id], r > 0 else { return [:] }
                return scaled(difference(p, q), 1 / r)
            case .vccs, .cccs:
                return controlRow(component).map { scaled($0, component.value ?? 0) }
            default:
                // Switched-off and taken-out sources, blocking diodes.
                return [:]
            }
        }

        var matrix: [[Double]] = []
        var vector: [Double] = []
        func add(_ row: Row, _ constant: Double) {
            var dense = [Double](repeating: 0, count: count)
            for (i, k) in row { dense[i] += k }
            matrix.append(dense)
            vector.append(constant)
        }
        // Kirchhoff's current law in every node but nodeB: out = the test current in.
        var outOf: [Int: Row] = [:]
        for component in components {
            guard let i = current(component) else { return nil }
            outOf[node(component.start), default: [:]].merge(i, uniquingKeysWith: +)
            outOf[node(component.end), default: [:]].merge(i.mapValues { -$0 }, uniquingKeysWith: +)
        }
        for n in index.keys.sorted() { add(outOf[n] ?? [:], n == nodeA ? 1 : 0) }
        // The branches that set a voltage.
        for component in components {
            guard branch[component.id] != nil else { continue }
            var row = difference(node(component.end), node(component.start))
            if component.kind == .vcvs || component.kind == .ccvs {
                guard let control = controlRow(component) else { return nil }
                row.merge(scaled(control, -(component.value ?? 0)), uniquingKeysWith: +)
            }
            add(row, 0)
        }
        // The controlling currents.
        for (_, control) in controlCurrent {
            var row: Row = [control.unknown: 1]
            for component in components {
                guard let k = control.coefficients[component.id], k != 0, let i = current(component) else { continue }
                row.merge(scaled(i, -k), uniquingKeysWith: +)
            }
            add(row, 0)
        }
        guard let ia = index[nodeA], let x = LinearAlgebra.solve(matrix, vector) else { return nil }

        // The resistors carrying part of the test current.
        var used = Set<UUID>()
        for component in components where component.kind == .resistor {
            guard let i = current(component) else { continue }
            if abs(i.reduce(0) { $0 + $1.value * x[$1.key] }) > 1e-9 { used.insert(component.id) }
        }
        return .value(x[ia], resistors: used)
    }
}

nonisolated extension Netlist {
    /// The node at a grid point: a connection point, a bend, or any point
    /// along a wire. `nil` if nothing is there.
    func node(at point: GridPoint) -> Int? {
        if let node = nodeOf[point] { return node }
        guard let edge = edges.first(where: { $0.wireID != nil && Circuit.point(point, isInteriorOf: $0.a, $0.b) }) else {
            return nil
        }
        return nodeOf[edge.a]
    }
}

// MARK: - Netlist

/// Groups connected points into nodes.
nonisolated struct Netlist {
    /// A piece of wire between two connection points (or a virtual link between ground symbols).
    struct Edge {
        var a: GridPoint
        var b: GridPoint
        var wireID: UUID?
    }

    private(set) var nodeOf: [GridPoint: Int] = [:]
    private(set) var nodeCount = 0
    /// All ground symbols form one node, the 0 V reference.
    private(set) var groundNode: Int?
    private(set) var edges: [Edge] = []

    init(_ circuit: Circuit) {
        var parent: [GridPoint: GridPoint] = [:]
        func find(_ point: GridPoint) -> GridPoint {
            var root = point
            while let next = parent[root], next != root { root = next }
            return root
        }
        func union(_ a: GridPoint, _ b: GridPoint) {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB { parent[rootA] = rootB }
        }

        // Points where things can connect. Bends only matter within their own wire.
        var connectionPoints = Set<GridPoint>()
        for wire in circuit.wires {
            connectionPoints.insert(wire.start)
            connectionPoints.insert(wire.end)
        }
        for component in circuit.components {
            connectionPoints.insert(component.start)
            connectionPoints.insert(component.end)
        }
        connectionPoints.formUnion(circuit.grounds.map(\.position))
        connectionPoints.formUnion(circuit.probes.map(\.position))
        connectionPoints.formUnion(circuit.probes.compactMap(\.negative))
        // The + and − points of voltage-controlled sources connect where they're placed.
        connectionPoints.formUnion(circuit.senses.filter { $0.kind != .current }.map(\.gridPoint))
        for point in connectionPoints where parent[point] == nil {
            parent[point] = point
        }

        var edgeList: [Edge] = []
        for wire in circuit.wires {
            for (a, b) in wire.segments {
                var onSegment = [a, b]
                onSegment += connectionPoints.filter { Circuit.point($0, isInteriorOf: a, b) }
                onSegment.sort { ($0.x, $0.y) < ($1.x, $1.y) }
                for (p, q) in zip(onSegment, onSegment.dropFirst()) where p != q {
                    union(p, q)
                    edgeList.append(Edge(a: p, b: q, wireID: wire.id))
                }
            }
        }
        if let first = circuit.grounds.first?.position {
            for ground in circuit.grounds.dropFirst() {
                union(first, ground.position)
                edgeList.append(Edge(a: first, b: ground.position, wireID: nil))
            }
        }

        var indexOfRoot: [GridPoint: Int] = [:]
        var nodes: [GridPoint: Int] = [:]
        for point in parent.keys.sorted(by: { ($0.x, $0.y) < ($1.x, $1.y) }) {
            let root = find(point)
            if indexOfRoot[root] == nil { indexOfRoot[root] = indexOfRoot.count }
            nodes[point] = indexOfRoot[root]
        }
        nodeOf = nodes
        nodeCount = indexOfRoot.count
        edges = edgeList
        groundNode = circuit.grounds.first.flatMap { nodes[$0.position] }
    }
}

nonisolated extension Netlist {
    /// The current in a wire under a current arrow, as ±1 times the current of
    /// each component (flowing from its start to its end terminal). Cutting the
    /// wire piece under the arrow splits its node in two; the current through
    /// the piece equals what the components feed into the side the arrow
    /// comes from. `nil` if the wire is part of a loop of wires.
    ///
    /// Both sides of the wire give the same current (Kirchhoff's current law);
    /// `fromOtherSide` picks which side's components the result is written with.
    func componentCoefficients(for arrow: CurrentArrow, in circuit: Circuit, fromOtherSide: Bool = false) -> [UUID: Double]? {
        guard let placement = circuit.placement(of: arrow) else { return nil }
        let point = placement.point
        let direction = placement.direction
        func contains(_ edge: Edge, _ p: CGPoint) -> Bool {
            p.distance(toSegment: CGPoint(x: edge.a.x, y: edge.a.y), CGPoint(x: edge.b.x, y: edge.b.y)) < 1e-6
        }
        let ahead = CGPoint(x: point.x + direction.x * 0.01, y: point.y + direction.y * 0.01)
        let candidates = edges.indices.filter { edges[$0].wireID == arrow.wireID && contains(edges[$0], point) }
        guard let edgeIndex = candidates.first(where: { contains(edges[$0], ahead) }) ?? candidates.first else {
            return nil
        }
        let edge = edges[edgeIndex]

        // Everything reachable from one end without crossing the arrow's wire piece.
        var neighbors: [GridPoint: [GridPoint]] = [:]
        for (index, other) in edges.enumerated() where index != edgeIndex {
            neighbors[other.a, default: []].append(other.b)
            neighbors[other.b, default: []].append(other.a)
        }
        let origin = fromOtherSide ? edge.b : edge.a
        let far = fromOtherSide ? edge.a : edge.b
        var side: Set<GridPoint> = [origin]
        var queue = [origin]
        while let next = queue.popLast() {
            for neighbor in neighbors[next] ?? [] where !side.contains(neighbor) {
                side.insert(neighbor)
                queue.append(neighbor)
            }
        }
        // Reaching the other end means the wire is part of a loop of wires.
        if side.contains(far) { return nil }

        // What the components feed into the side leaves it through the wire,
        // i.e. flows from `origin` towards `far`.
        let alongEdge = direction.x * Double(far.x - origin.x) + direction.y * Double(far.y - origin.y)
        let sign: Double = alongEdge >= 0 ? 1 : -1
        var coefficients: [UUID: Double] = [:]
        for component in circuit.components {
            if side.contains(component.start) { coefficients[component.id, default: 0] -= sign }
            if side.contains(component.end) { coefficients[component.id, default: 0] += sign }
        }
        return coefficients.filter { $0.value != 0 }
    }
}

// MARK: - Equations

/// `Σ linear·x + Σ coefficient·x[a]·x[b] + Σ coefficient·e^x[a]·x[b] + constant = 0`
///
/// The exponential terms are for unknown resistances, which are solved as
/// R = e^u so they can only come out positive.
nonisolated struct Equation {
    var linear: [Int: Double] = [:]
    var bilinear: [(a: Int, b: Int, coefficient: Double)] = []
    var exponential: [(a: Int, b: Int, coefficient: Double)] = []
    var constant = 0.0
    /// Names of the items the equation comes from, to explain conflicts.
    var sources: [String]

    func value(_ x: [Double]) -> Double {
        var sum = constant
        for (index, coefficient) in linear { sum += coefficient * x[index] }
        for term in bilinear { sum += term.coefficient * x[term.a] * x[term.b] }
        for term in exponential { sum += term.coefficient * safeExp(x[term.a]) * x[term.b] }
        return sum
    }

    func gradient(_ x: [Double], count: Int) -> [Double] {
        var result = [Double](repeating: 0, count: count)
        for (index, coefficient) in linear { result[index] += coefficient }
        for term in bilinear {
            result[term.a] += term.coefficient * x[term.b]
            result[term.b] += term.coefficient * x[term.a]
        }
        for term in exponential {
            let e = safeExp(x[term.a])
            result[term.a] += term.coefficient * e * x[term.b]
            result[term.b] += term.coefficient * e
        }
        return result
    }

    /// The size of the terms, used to judge whether the residual is "zero".
    func magnitude(_ x: [Double]) -> Double {
        var sum = abs(constant)
        for (index, coefficient) in linear { sum += abs(coefficient * x[index]) }
        for term in bilinear { sum += abs(term.coefficient * x[term.a] * x[term.b]) }
        for term in exponential { sum += abs(term.coefficient * safeExp(x[term.a]) * x[term.b]) }
        return sum
    }
}

/// `e^x`, kept finite so the solver can't overflow.
nonisolated func safeExp(_ x: Double) -> Double {
    exp(min(max(x, -60), 60))
}

// MARK: - Model

nonisolated private struct Model {
    enum VariableKind {
        case voltage, current, parameter
        /// The logarithm of an unknown resistance (R = e^u).
        case logResistance
    }

    /// A value the user can see but hasn't entered.
    struct Unknown {
        enum Target { case component(UUID), probe(UUID), current(UUID) }
        var name: String
        var target: Target
        /// The value as a linear function of the variables, or `nil` if it can't
        /// be expressed at all (a current arrow in a loop of wires).
        var expression: [Int: Double]?
    }

    let circuit: Circuit
    let netlist: Netlist
    /// The diodes assumed to conduct; the others block.
    let conducting: Set<UUID>
    var kinds: [VariableKind] = []
    var initial: [Double] = []
    var voltageVariable: [Int: Int] = [:]
    var currentVariable: [UUID: Int] = [:]
    var parameterVariable: [UUID: Int] = [:]
    var equations: [Equation] = []
    var unknowns: [Unknown] = []
    var issues: [SolverIssue] = []

    /// The variables at the solution, set by `solve()`.
    private(set) var point: [Double] = []

    init(circuit: Circuit, conducting: Set<UUID> = []) {
        self.circuit = circuit
        self.netlist = Netlist(circuit)
        self.conducting = conducting
        buildVariables()
        buildEquations()
        buildUnknowns()
    }

    private mutating func addVariable(_ kind: VariableKind, initial value: Double) -> Int {
        kinds.append(kind)
        initial.append(value)
        return kinds.count - 1
    }

    /// The variable holding a point's voltage, or `nil` for ground (always 0 V).
    /// A voltage point's voltage, or a voltage drop's V(+) − V(−), as a linear
    /// function of the variables. A point on the ground node counts as 0 V.
    /// `nil` when one of a voltage drop's points isn't on the circuit.
    private func expression(for probe: Probe) -> [Int: Double]? {
        var expression: [Int: Double] = [:]
        if let variable = voltage(at: probe.position) { expression[variable, default: 0] += 1 }
        if let negative = probe.negative {
            guard netlist.nodeOf[probe.position] != nil, netlist.nodeOf[negative] != nil else { return nil }
            if let variable = voltage(at: negative) { expression[variable, default: 0] -= 1 }
        }
        return expression.filter { $0.value != 0 }
    }

    private func voltage(at point: GridPoint) -> Int? {
        guard let node = netlist.nodeOf[point], node != netlist.groundNode else { return nil }
        return voltageVariable[node]
    }

    private mutating func buildVariables() {
        for node in 0..<netlist.nodeCount where node != netlist.groundNode {
            voltageVariable[node] = addVariable(.voltage, initial: 0)
        }
        for component in circuit.components {
            currentVariable[component.id] = addVariable(.current, initial: 0)
            if component.value == nil {
                parameterVariable[component.id] = switch component.kind {
                case .resistor: addVariable(.logResistance, initial: log(1000))
                case .voltageSource: addVariable(.parameter, initial: 1)
                case .currentSource: addVariable(.parameter, initial: 0.001)
                case .vcvs, .ccvs, .vccs, .cccs: addVariable(.parameter, initial: 1)
                case .diode: addVariable(.parameter, initial: 0.7)
                case .led: addVariable(.parameter, initial: 2)
                }
            }
        }
    }

    private mutating func buildEquations() {
        var kcl: [Int: Equation] = [:]

        for component in circuit.components {
            guard let current = currentVariable[component.id] else { continue }
            let start = voltage(at: component.start)
            let end = voltage(at: component.end)
            var equation = Equation(sources: [component.name])

            switch component.kind {
            case .resistor:
                // v(start) − v(end) − R·i = 0
                if let start { equation.linear[start, default: 0] += 1 }
                if let end { equation.linear[end, default: 0] -= 1 }
                if let value = component.value {
                    equation.linear[current, default: 0] -= value
                } else if let parameter = parameterVariable[component.id] {
                    // R = e^u keeps an unknown resistance positive.
                    equation.exponential.append((parameter, current, -1))
                }
            case .voltageSource:
                // v(+) − v(−) − E = 0, with + at the end terminal
                if let end { equation.linear[end, default: 0] += 1 }
                if let start { equation.linear[start, default: 0] -= 1 }
                if let value = component.value {
                    equation.constant = -value
                } else if let parameter = parameterVariable[component.id] {
                    equation.linear[parameter] = -1
                }
            case .currentSource:
                // i − J = 0, flowing from start to end through the source
                equation.linear[current] = 1
                if let value = component.value {
                    equation.constant = -value
                } else if let parameter = parameterVariable[component.id] {
                    equation.linear[parameter] = -1
                }
            case .diode, .led:
                if conducting.contains(component.id) {
                    // v(anode) − v(cathode) − Vf = 0, with the anode at the start terminal
                    if let start { equation.linear[start, default: 0] += 1 }
                    if let end { equation.linear[end, default: 0] -= 1 }
                    if let value = component.value {
                        equation.constant = -value
                    } else if let parameter = parameterVariable[component.id] {
                        equation.linear[parameter] = -1
                    }
                } else {
                    // A blocking diode carries no current: i = 0
                    equation.linear[current] = 1
                }
            case .vcvs, .ccvs, .vccs, .cccs:
                // v(+) − v(−) − gain·control = 0, or i − gain·control = 0
                guard let control = control(of: component) else {
                    issues.append(SolverIssue(
                        kind: .missing,
                        title: "\(component.name) mangler sin styring",
                        detail: component.kind.isVoltageControlled
                            ? "Træk + og − punkterne (Vs) for \(component.name) hen på de to steder i kredsløbet, spændingen skal måles imellem."
                            : "Træk Is-punktet for \(component.name) hen på den ledning, hvor den styrende strøm løber. Ledningen må ikke indgå i en løkke af ledninger."
                    ))
                    // Without its control the source adds no equation.
                    break
                }
                if component.kind.setsVoltage {
                    if let end { equation.linear[end, default: 0] += 1 }
                    if let start { equation.linear[start, default: 0] -= 1 }
                } else {
                    equation.linear[current, default: 0] += 1
                }
                if let gain = component.value {
                    for (variable, coefficient) in control {
                        equation.linear[variable, default: 0] -= gain * coefficient
                    }
                } else if let parameter = parameterVariable[component.id] {
                    for (variable, coefficient) in control {
                        equation.bilinear.append((parameter, variable, -coefficient))
                    }
                }
            }
            if component.kind.isDependent && control(of: component) == nil {
                // No equation for a controlled source without its control.
            } else {
                equations.append(equation)
            }

            // Kirchhoff's current law: the component's current leaves the node at
            // its start terminal and enters the node at its end terminal.
            if let node = netlist.nodeOf[component.start] {
                kcl[node, default: Equation(sources: [])].linear[current, default: 0] -= 1
                kcl[node]?.sources.append(component.name)
            }
            if let node = netlist.nodeOf[component.end] {
                kcl[node, default: Equation(sources: [])].linear[current, default: 0] += 1
                kcl[node]?.sources.append(component.name)
            }
        }
        equations += kcl.keys.sorted().compactMap { kcl[$0] }

        for probe in circuit.probes {
            guard let value = probe.value, let expression = expression(for: probe) else { continue }
            var equation = Equation(linear: expression, sources: [probe.name])
            equation.constant = -value
            equations.append(equation)
        }

        for arrow in circuit.currents {
            guard let value = arrow.value, let expression = expression(for: arrow) else { continue }
            var equation = Equation(linear: expression, sources: [arrow.name])
            equation.constant = -value
            equations.append(equation)
        }
    }

    private mutating func buildUnknowns() {
        for component in circuit.components where component.value == nil {
            if let parameter = parameterVariable[component.id] {
                unknowns.append(Unknown(name: component.name, target: .component(component.id), expression: [parameter: 1]))
            }
        }
        for probe in circuit.probes where probe.value == nil {
            guard let expression = expression(for: probe) else { continue }
            unknowns.append(Unknown(name: probe.name, target: .probe(probe.id), expression: expression))
        }
        for arrow in circuit.currents where arrow.value == nil {
            unknowns.append(Unknown(name: arrow.name, target: .current(arrow.id), expression: expression(for: arrow)))
        }
    }

    /// The controlling quantity of a controlled source as a linear function
    /// of the variables: the voltage between its + and − sense points (Vs),
    /// or the current in the wire under its Is marker. `nil` if the markers
    /// aren't placed on the circuit.
    private func control(of component: CircuitComponent) -> [Int: Double]? {
        if component.kind.isVoltageControlled {
            guard let plus = circuit.sense(of: component.id, .plus),
                  let minus = circuit.sense(of: component.id, .minus),
                  isOnCircuit(plus.gridPoint), isOnCircuit(minus.gridPoint) else { return nil }
            var result: [Int: Double] = [:]
            if let variable = voltage(at: plus.gridPoint) { result[variable, default: 0] += 1 }
            if let variable = voltage(at: minus.gridPoint) { result[variable, default: 0] -= 1 }
            return result
        }
        if component.kind.isCurrentControlled {
            guard let marker = circuit.sense(of: component.id, .current),
                  let arrow = circuit.currentArrow(for: marker) else { return nil }
            return expression(for: arrow)
        }
        return nil
    }

    /// Whether a point is part of a node that something is connected to.
    private func isOnCircuit(_ point: GridPoint) -> Bool {
        guard let node = netlist.nodeOf[point] else { return false }
        if node == netlist.groundNode { return true }
        return circuit.components.contains { netlist.nodeOf[$0.start] == node || netlist.nodeOf[$0.end] == node }
    }

    /// The current in a wire, as a sum of component currents.
    private func expression(for arrow: CurrentArrow) -> [Int: Double]? {
        guard let coefficients = netlist.componentCoefficients(for: arrow, in: circuit) else { return nil }
        var result: [Int: Double] = [:]
        for (id, coefficient) in coefficients {
            if let current = currentVariable[id] { result[current, default: 0] += coefficient }
        }
        return result
    }

    // MARK: Solving

    mutating func solve() -> CircuitSolution {
        var solution = CircuitSolution()
        solution.unknownCount = unknowns.count
        let count = kinds.count
        let x = count > 0 ? bestSolution() : []
        point = x

        // Are the known values consistent?
        let conflicting = equations.filter { abs($0.value(x)) > 1e-6 * $0.magnitude(x) + 1e-9 }
        let negativeResistors = circuit.components.filter { $0.kind == .resistor && ($0.value ?? 1) < 0 }
        solution.isConsistent = conflicting.isEmpty && negativeResistors.isEmpty
        for resistor in negativeResistors {
            issues.append(SolverIssue(
                kind: .conflict,
                title: "\(resistor.name) er negativ",
                detail: "En modstand kan ikke være negativ. Ret værdien af \(resistor.name)."
            ))
        }
        if !conflicting.isEmpty {
            let names = Array(Set(conflicting.flatMap(\.sources))).sorted()
            let hasUnknownResistors = circuit.components.contains { $0.kind == .resistor && $0.value == nil }
            let reason = hasUnknownResistors
                ? " Ingen positive værdier for de ukendte modstande kan give de kendte værdier – fx kan en spænding ikke blive højere end kilden uden en strømkilde."
                : ""
            issues.append(SolverIssue(
                kind: .conflict,
                title: "Værdierne passer ikke sammen",
                detail: "De kendte værdier modsiger hinanden, så intet kan beregnes.\(reason) Tjek værdierne ved: \(names.joined(separator: ", "))."
            ))
        }

        if netlist.groundNode == nil, !circuit.probes.isEmpty || !circuit.components.isEmpty {
            issues.append(SolverIssue(
                kind: .notice,
                title: "Der mangler et stel (0 V)",
                detail: "Spændinger i punkterne måles i forhold til stel. Sæt et stel-symbol (G) på det punkt, der skal være 0 V."
            ))
        }

        let rank = RankTester(equations: equations, x: x, kinds: kinds)
        for unknown in unknowns {
            guard let expression = unknown.expression else {
                issues.append(SolverIssue(
                    kind: .missing,
                    title: "\(unknown.name) kan ikke beregnes",
                    detail: "Strømpilen sidder på en ledning i en løkke af ledninger, så strømmen kan fordele sig på flere måder. Flyt pilen til en ledning uden parallelforbindelse."
                ))
                continue
            }
            if solution.isConsistent, rank.isDetermined(expression) {
                var value = expression.reduce(0) { $0 + $1.value * x[$1.key] }
                // Unknown resistances are solved as their logarithm.
                if case .component = unknown.target, expression.count == 1,
                   let variable = expression.keys.first, kinds[variable] == .logResistance {
                    value = safeExp(x[variable])
                }
                switch unknown.target {
                case .component(let id): solution.componentValues[id] = value
                case .probe(let id): solution.probeValues[id] = value
                case .current(let id): solution.currentValues[id] = value
                }
                solution.solvedCount += 1
            } else if solution.isConsistent {
                // Which other unknown value would make this one computable?
                let helpers = unknowns.filter { other in
                    guard other.name != unknown.name, let helper = other.expression else { return false }
                    return rank.isDetermined(expression, given: helper)
                }.map(\.name)
                let detail = helpers.isEmpty
                    ? "Der mangler flere kendte værdier i den del af kredsløbet, eller den er ikke forbundet til resten."
                    : "Angiv én af disse værdier: \(helpers.joined(separator: ", "))."
                issues.append(SolverIssue(kind: .missing, title: "\(unknown.name) kan ikke beregnes endnu", detail: detail))
            }
        }

        // The power absorbed by each component with a power circle: the
        // voltage from start to end times the current from start to end.
        // It's known when both the voltage and the current are.
        for component in circuit.components where component.isPowerShown {
            guard let current = currentVariable[component.id] else { continue }
            solution.unknownCount += 1
            var voltage: [Int: Double] = [:]
            if let start = self.voltage(at: component.start) { voltage[start, default: 0] += 1 }
            if let end = self.voltage(at: component.end) { voltage[end, default: 0] -= 1 }
            voltage = voltage.filter { $0.value != 0 }
            let isOnCircuit = netlist.nodeOf[component.start] != nil && netlist.nodeOf[component.end] != nil
            if solution.isConsistent, isOnCircuit, rank.isDetermined(voltage), rank.isDetermined([current: 1]) {
                let u = voltage.reduce(0) { $0 + $1.value * x[$1.key] }
                solution.powerValues[component.id] = u * x[current]
                solution.solvedCount += 1
            } else if solution.isConsistent {
                issues.append(SolverIssue(
                    kind: .missing,
                    title: "\(component.powerName) kan ikke beregnes endnu",
                    detail: "Effekten i \(component.name) kræver både spændingen over og strømmen gennem \(component.name). Der mangler flere kendte værdier i den del af kredsløbet."
                ))
            }
        }

        // Each diode's current (anode to cathode) and voltage, for checking
        // its state like by hand.
        if solution.isConsistent {
            for component in circuit.components where component.kind.isDiode {
                guard let current = currentVariable[component.id] else { continue }
                // No voltage variable is the 0 V reference.
                let start = self.voltage(at: component.start).map { x[$0] } ?? 0
                let end = self.voltage(at: component.end).map { x[$0] } ?? 0
                solution.diodeValues[component.id] = (voltage: start - end, current: x[current])
            }
        }

        solution.issues = issues
        return solution
    }

    /// The diode whose assumed state fits the solution worst, or `nil` if all
    /// fit: a conducting diode must carry current forwards, and a blocking
    /// one can't have more than its forward voltage across it.
    func worstDiodeViolation() -> UUID? {
        var worst: (id: UUID, amount: Double)?
        for component in circuit.components where component.kind.isDiode {
            let amount: Double
            if conducting.contains(component.id) {
                guard let current = currentVariable[component.id] else { continue }
                // Relative to 1 mA, so tiny numerical noise doesn't count.
                amount = -point[current] / 1e-3
            } else {
                let start = voltage(at: component.start).map { point[$0] } ?? 0
                let end = voltage(at: component.end).map { point[$0] } ?? 0
                let forward = component.value ?? parameterVariable[component.id].map { point[$0] } ?? 0
                amount = (start - end - forward) / max(abs(forward), 0.1)
            }
            if amount > 1e-6, amount > (worst?.amount ?? 0) { worst = (component.id, amount) }
        }
        return worst?.id
    }

    /// Whether every equation holds at `x`.
    private func satisfiesAll(_ x: [Double]) -> Bool {
        equations.allSatisfy { abs($0.value(x)) <= 1e-6 * $0.magnitude(x) + 1e-9 }
    }

    /// Runs the solver from several starting guesses for the unknown
    /// resistances, since with more than one of them a single start can get
    /// stuck. Returns the first solution that satisfies all equations, or the
    /// best one found.
    private func bestSolution() -> [Double] {
        let logResistances = kinds.indices.filter { kinds[$0] == .logResistance }
        var starts = [initial]
        if !logResistances.isEmpty {
            let guesses: [Double] = [100, 10, 10_000, 1, 100_000]
            for guess in guesses {
                var start = initial
                for index in logResistances { start[index] = log(guess) }
                starts.append(start)
            }
            // Mixed guesses, so the unknown resistances can differ a lot.
            var seed: UInt64 = 0x9E3779B97F4A7C15
            for _ in 0..<12 {
                var start = initial
                for index in logResistances {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let fraction = Double(seed >> 11) / Double(1 << 53)
                    start[index] = log(1) + fraction * (log(1_000_000) - log(1))
                }
                starts.append(start)
            }
        }

        var best: (x: [Double], cost: Double)?
        for start in starts {
            let result = levenbergMarquardt(from: start)
            if satisfiesAll(result.x) { return result.x }
            if result.cost < (best?.cost ?? .infinity) { best = result }
        }
        return best?.x ?? initial
    }

    /// Finds a point near `start` where all equations hold as well as possible.
    private func levenbergMarquardt(from start: [Double]) -> (x: [Double], cost: Double) {
        let count = kinds.count
        var x = start
        var lambda = 1e-3
        var finalCost = Double.infinity

        for _ in 0..<500 {
            // Rows are scaled to unit gradient so volts and amperes weigh alike.
            let gradients = equations.map { $0.gradient(x, count: count) }
            let weights = gradients.map { gradient -> Double in
                let norm = sqrt(gradient.reduce(0) { $0 + $1 * $1 })
                return norm > 1e-12 ? 1 / norm : 1
            }
            func cost(_ point: [Double]) -> Double {
                zip(equations, weights).reduce(0) { sum, pair in
                    let r = pair.0.value(point) * pair.1
                    return sum + r * r
                }
            }
            let currentCost = cost(x)
            finalCost = currentCost
            if currentCost < 1e-26 { break }

            var normal = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
            var rhs = [Double](repeating: 0, count: count)
            for (row, equation) in equations.enumerated() {
                let weight = weights[row]
                let residual = equation.value(x) * weight
                let gradient = gradients[row]
                for i in 0..<count where gradient[i] != 0 {
                    let gi = gradient[i] * weight
                    rhs[i] -= gi * residual
                    for j in 0..<count where gradient[j] != 0 {
                        normal[i][j] += gi * gradient[j] * weight
                    }
                }
            }

            var accepted = false
            for _ in 0..<12 {
                var damped = normal
                for i in 0..<count {
                    damped[i][i] += lambda * (normal[i][i] + 1e-9)
                }
                guard let step = LinearAlgebra.solve(damped, rhs) else { lambda *= 4; continue }
                let candidate = zip(x, step).map(+)
                if cost(candidate) < currentCost {
                    x = candidate
                    lambda = max(lambda / 3, 1e-12)
                    accepted = true
                    break
                }
                lambda *= 4
            }
            if !accepted { break }
        }
        return (x, finalCost)
    }
}

// MARK: - Rank tests

/// Decides whether a quantity is uniquely determined by the equations near
/// the solution: its gradient must lie in the row space of the Jacobian.
nonisolated private struct RankTester {
    let rows: [[Double]]
    let scales: [Double]
    let baseRank: Int

    init(equations: [Equation], x: [Double], kinds: [Model.VariableKind]) {
        let count = x.count
        // Scale columns to typical sizes so volts, amperes and ohms compare fairly.
        let voltageScale = max(1, zip(x, kinds).filter { $0.1 == .voltage }.map { abs($0.0) }.max() ?? 0)
        let currentScale = max(voltageScale / 1e6, zip(x, kinds).filter { $0.1 == .current }.map { abs($0.0) }.max() ?? 0)
        scales = zip(x, kinds).map { value, kind in
            switch kind {
            case .voltage: voltageScale
            case .current: currentScale
            case .parameter: max(abs(value), 1e-9)
            case .logResistance: 1
            }
        }
        let scales = scales
        rows = equations.map { equation in
            let gradient = equation.gradient(x, count: count)
            return RankTester.normalized(zip(gradient, scales).map(*))
        }
        baseRank = LinearAlgebra.rank(rows)
    }

    private static func normalized(_ row: [Double]) -> [Double] {
        let norm = sqrt(row.reduce(0) { $0 + $1 * $1 })
        return norm > 1e-300 ? row.map { $0 / norm } : row
    }

    private func row(_ expression: [Int: Double]) -> [Double] {
        var result = [Double](repeating: 0, count: scales.count)
        for (index, coefficient) in expression { result[index] = coefficient * scales[index] }
        return RankTester.normalized(result)
    }

    func isDetermined(_ expression: [Int: Double]) -> Bool {
        if expression.values.allSatisfy({ $0 == 0 }) { return true }
        return LinearAlgebra.rank(rows + [row(expression)]) == baseRank
    }

    /// Whether the quantity would be determined if `helper` were known too.
    func isDetermined(_ expression: [Int: Double], given helper: [Int: Double]) -> Bool {
        let withHelper = rows + [row(helper)]
        return LinearAlgebra.rank(withHelper + [row(expression)]) == LinearAlgebra.rank(withHelper)
    }
}

// MARK: - Linear algebra

nonisolated enum LinearAlgebra {
    /// Solves `A·x = b` by Gaussian elimination with partial pivoting.
    static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        let n = vector.count
        var a = matrix
        var b = vector
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                  abs(a[pivot][column]) > 1e-300 else { return nil }
            a.swapAt(column, pivot)
            b.swapAt(column, pivot)
            for row in (column + 1)..<n where a[row][column] != 0 {
                let factor = a[row][column] / a[column][column]
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x
    }

    /// Numerical rank by Gaussian elimination with full pivoting.
    static func rank(_ matrix: [[Double]], tolerance: Double = 1e-9) -> Int {
        var a = matrix
        let rows = a.count
        guard rows > 0 else { return 0 }
        let columns = a[0].count
        var rank = 0
        var usedColumns = Set<Int>()
        while rank < rows {
            var best = (row: -1, column: -1, value: tolerance)
            for row in rank..<rows {
                for column in 0..<columns where !usedColumns.contains(column) && abs(a[row][column]) > best.value {
                    best = (row, column, abs(a[row][column]))
                }
            }
            guard best.row >= 0 else { break }
            a.swapAt(rank, best.row)
            usedColumns.insert(best.column)
            let pivot = a[rank][best.column]
            for row in (rank + 1)..<rows where a[row][best.column] != 0 {
                let factor = a[row][best.column] / pivot
                for column in 0..<columns { a[row][column] -= factor * a[rank][column] }
            }
            rank += 1
        }
        return rank
    }
}
