#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// MARK: - Sheet mode

/// What a sheet is for, chosen on the start page: analog circuits
/// (components, sources and the solver) or digital logic (gates).
nonisolated enum SheetMode: String, Codable, CaseIterable, Identifiable {
    case analog
    case digital

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .analog: "Analog"
        case .digital: "Digital"
        }
    }
}

// MARK: - Logic gates

/// The logic symbols of a digital sheet: gates, and the inputs and outputs
/// the truth table is made from.
nonisolated enum GateKind: String, Codable, CaseIterable, Identifiable {
    case and
    case or
    case not
    case nand
    case nor
    case xor
    case xnor
    /// A named input (A, B, …) that is 0 or 1; clicking it switches it.
    case input
    /// A named output (Y, …) showing the value that reaches it.
    case output
    /// A box (a module, like an IC) with named inputs on the left and named
    /// outputs on the right. What it does is built in its sub-diagram
    /// (`LogicGate.subcircuit`).
    case block
    /// A 5 V supply flag: always 1.
    case high
    /// A ground (GND) flag: always 0.
    case low

    var id: String { rawValue }

    static let gates: [GateKind] = [.and, .or, .not, .nand, .nor, .xor, .xnor]

    /// The input counts a gate with more than one input can have.
    static let inputRange = 2...8

    var displayName: String {
        switch self {
        case .and: "AND-gate"
        case .or: "OR-gate"
        case .not: "NOT-gate (inverter)"
        case .nand: "NAND-gate"
        case .nor: "NOR-gate"
        case .xor: "XOR-gate"
        case .xnor: "XNOR-gate"
        case .input: "Indgang"
        case .output: "Udgang"
        case .block: "Blok (modul)"
        case .high: "5V (altid 1)"
        case .low: "GND (altid 0)"
        }
    }

    /// "AND", "OR", …, as in gate lists.
    var shortName: String {
        switch self {
        case .input: "Indgang"
        case .output: "Udgang"
        case .block: "Blok"
        case .high: "5V"
        case .low: "GND"
        default: rawValue.uppercased()
        }
    }

    var isGate: Bool { Self.gates.contains(self) }
    /// 5V and GND: a fixed 1 or 0, with one terminal.
    var isConstant: Bool { self == .high || self == .low }
    /// NOT, NAND, NOR and XNOR invert: a small circle at the output.
    var hasBubble: Bool { self == .not || self == .nand || self == .nor || self == .xnor }
    /// Gates other than NOT can have 2 to 8 inputs.
    var allowsMoreInputs: Bool { isGate && self != .not }

    var defaultInputCount: Int {
        switch self {
        case .input, .block, .high, .low: 0
        case .not, .output: 1
        default: 2
        }
    }

    func evaluate(_ inputs: [Bool]) -> Bool {
        switch self {
        case .and: inputs.allSatisfy { $0 }
        case .or: inputs.contains(true)
        case .not: !(inputs.first ?? false)
        case .nand: !inputs.allSatisfy { $0 }
        case .nor: !inputs.contains(true)
        case .xor: inputs.filter { $0 }.count % 2 == 1
        case .xnor: inputs.filter { $0 }.count % 2 == 0
        case .input, .output: inputs.first ?? false
        case .high: true
        case .low: false
        // A block's outputs are worked out through its sub-diagram.
        case .block: false
        }
    }
}

/// A gate, input, output or block on a digital sheet.
///
/// In its own frame (rotation 0) the signal runs to the right: a gate has
/// its inputs on the line x = 0 and its output at x = 5; an input has its
/// terminal at `position` with its box to the left, and an output its
/// terminal at `position` with its box to the right. A block has its inputs
/// on x = 0 and its outputs on x = `blockLength`, one row per grid unit
/// from y = 0 down, with its box in between. `rotation` turns the whole
/// symbol in quarter turns clockwise around `position`.
nonisolated struct LogicGate: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: GateKind
    var position: GridPoint
    var rotation = 0
    var inputCount: Int
    /// The name of an input or output (A, B, Y, …). Inputs with the same
    /// name are the same signal.
    var name = ""
    /// Whether an input is 1 right now.
    var isHigh: Bool?
    var note = ""
    /// Inputs (by their offset across the gate) with a small circle that
    /// inverts the signal coming in, put there with the inverter tool.
    var invertedInputs: [Int]?
    /// Whether the signal going out is inverted (a circle at the output).
    var invertsOutput: Bool?
    /// A block's input and output names, one per row from the top. An empty
    /// name leaves a gap (no terminal) in that row.
    var blockInputs: [String]?
    var blockOutputs: [String]?
    /// A block's outputs (by row) with an inverting circle.
    var invertedOutputs: [Int]?
    /// What a block does: a sheet of its own whose inputs and outputs are
    /// matched to the block's terminals by name. `nil` until it's built.
    var subcircuit: Circuit?

    /// A terminal of the symbol: an input (by offset, a block's by row), the
    /// output, or one of a block's outputs (by row).
    enum Pin: Hashable {
        case input(Int)
        case output
        case blockOutput(Int)
    }

    func isInverted(_ pin: Pin) -> Bool {
        switch pin {
        case .input(let offset): invertedInputs?.contains(offset) == true
        case .output: invertsOutput == true
        case .blockOutput(let row): invertedOutputs?.contains(row) == true
        }
    }

    /// Puts an inverting circle on a terminal, or takes it away.
    mutating func toggleInversion(_ pin: Pin) {
        switch pin {
        case .input(let offset):
            var inverted = Set(invertedInputs ?? [])
            if inverted.contains(offset) { inverted.remove(offset) } else { inverted.insert(offset) }
            invertedInputs = inverted.isEmpty ? nil : inverted.sorted()
        case .output:
            invertsOutput = invertsOutput == true ? nil : true
        case .blockOutput(let row):
            var inverted = Set(invertedOutputs ?? [])
            if inverted.contains(row) { inverted.remove(row) } else { inverted.insert(row) }
            invertedOutputs = inverted.isEmpty ? nil : inverted.sorted()
        }
    }

    /// Every terminal with its grid point.
    var pins: [(pin: Pin, point: GridPoint)] {
        zip(inputOffsets, inputPoints).map { (Pin.input($0.0), $0.1) }
            + (outputPoint.map { [(Pin.output, $0)] } ?? [])
            + blockOutputPoints.map { (Pin.blockOutput($0.row), $0.point) }
    }

    /// Where a terminal's inverting circle sits, in the symbol's own frame.
    func bubbleCenter(_ pin: Pin) -> (x: Double, y: Double) {
        switch (kind, pin) {
        case (.input, _): (-0.3, 0)
        case (.high, _): (0, -0.3)
        case (.low, _): (0, 0.3)
        case (.output, _): (0.3, 0)
        case (.block, .input(let row)): (0.78, Double(row))
        case (_, .blockOutput(let row)): (Double(blockLength) - 0.78, Double(row))
        case (_, .input(let offset)): (0.55, Double(offset))
        case (.not, .output): (3.77, 0)
        case (_, .output): (4.22, 0)
        }
    }

    /// Whether the gate's output is drawn with a circle: its own (NOT, NAND,
    /// NOR, XNOR) or one put there, but not both, since they cancel out.
    var showsOutputBubble: Bool {
        kind.isGate ? kind.hasBubble != isInverted(.output) : isInverted(.output)
    }

    init(kind: GateKind, position: GridPoint, rotation: Int = 0, inputCount: Int? = nil, name: String = "") {
        self.kind = kind
        self.position = position
        self.rotation = rotation
        self.inputCount = inputCount ?? kind.defaultInputCount
        self.name = name
        if kind == .block {
            blockInputs = ["A", "B"]
            blockOutputs = ["Y"]
        }
    }

    // MARK: Blocks

    /// The rows of a block's inputs or outputs that have a name (and so a terminal).
    private static func namedRows(_ names: [String]?) -> [Int] {
        (names ?? []).indices.filter { !(names?[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// A block's name of an input or output row, trimmed.
    func blockPinName(_ pin: Pin) -> String {
        let (names, row): ([String]?, Int) = switch pin {
        case .input(let row): (blockInputs, row)
        case .blockOutput(let row): (blockOutputs, row)
        case .output: (nil, 0)
        }
        guard let names, names.indices.contains(row) else { return "" }
        return names[row].trimmingCharacters(in: .whitespaces)
    }

    /// The rows of a block's outputs.
    var blockOutputRows: [Int] { kind == .block ? Self.namedRows(blockOutputs) : [] }

    /// A block's outputs with their grid points.
    var blockOutputPoints: [(row: Int, point: GridPoint)] {
        blockOutputRows.map { ($0, gridPoint(GridPoint(x: blockLength, y: $0))) }
    }

    /// How many rows a block has: down to its last named terminal, at least one.
    var blockRows: Int {
        max(1, ((Self.namedRows(blockInputs) + blockOutputRows).max() ?? 0) + 1)
    }

    /// The width of a block's box in grid units, wide enough for the
    /// longest input and output names side by side.
    var blockBodyWidth: Int {
        let longest = { (names: [String]?) in (names ?? []).map { $0.trimmingCharacters(in: .whitespaces).count }.max() ?? 0 }
        return max(3, Int((Double(longest(blockInputs) + longest(blockOutputs)) * 0.36 + 1.2).rounded(.up)))
    }

    /// From a block's inputs to its outputs: a grid unit of lead on either
    /// side of the box.
    var blockLength: Int { blockBodyWidth + 2 }

    /// Pin names typed one per line, as a block keeps them.
    static func pinNames(from text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Renames the inputs and outputs of a block's sub-diagram whose
    /// terminal was renamed (the same row, another name), so what's wired to
    /// them inside stays.
    mutating func renameInsideTerminals(from old: LogicGate) {
        guard kind == .block, subcircuit != nil else { return }
        func renames(_ kind: GateKind, _ before: [String]?, _ after: [String]?) {
            for (row, oldName) in (before ?? []).enumerated() where row < (after ?? []).count {
                let from = oldName.trimmingCharacters(in: .whitespaces)
                let to = (after?[row] ?? "").trimmingCharacters(in: .whitespaces)
                guard !from.isEmpty, !to.isEmpty, from != to else { continue }
                for index in subcircuit!.gates.indices where subcircuit!.gates[index].kind == kind && subcircuit!.gates[index].name == from {
                    subcircuit!.gates[index].name = to
                }
            }
        }
        renames(.input, old.blockInputs, blockInputs)
        renames(.output, old.blockOutputs, blockOutputs)
    }

    /// From the inputs to the output of a gate, in grid units.
    static let length = 5

    /// Where the inputs sit across the gate: one grid unit apart, with the
    /// middle left free when there's an even number, so the output line
    /// stays clear.
    static func inputOffsets(_ count: Int) -> [Int] {
        guard count > 1 else { return [0] }
        let half = count / 2
        if count % 2 == 1 { return Array(-half...half) }
        return Array(-half ... -1) + Array(1...half)
    }

    var inputOffsets: [Int] {
        switch kind {
        case .input, .high, .low: []
        case .output, .not: [0]
        case .block: Self.namedRows(blockInputs)
        default: Self.inputOffsets(inputCount)
        }
    }

    /// Half the height of the gate's body, in grid units.
    var bodyHalfHeight: Double {
        kind == .not ? 1 : max(1.5, Double(inputOffsets.map(abs).max() ?? 0) + 0.5)
    }

    private var quarterTurns: Int { ((rotation % 4) + 4) % 4 }

    /// A point of the symbol's own frame on the grid.
    func gridPoint(_ local: GridPoint) -> GridPoint {
        var point = position + local
        for _ in 0..<quarterTurns { point = point.rotatedClockwise(around: position) }
        return point
    }

    /// A point of the symbol's own frame, in grid units.
    func point(_ x: Double, _ y: Double) -> CGPoint {
        let (dx, dy) = direction
        return CGPoint(
            x: Double(position.x) + x * dx - y * dy,
            y: Double(position.y) + x * dy + y * dx
        )
    }

    /// The way the signal runs (rotation 0: right).
    var direction: (Double, Double) {
        switch quarterTurns {
        case 1: (0, 1)
        case 2: (-1, 0)
        case 3: (0, -1)
        default: (1, 0)
        }
    }

    var inputPoints: [GridPoint] {
        inputOffsets.map { gridPoint(GridPoint(x: 0, y: $0)) }
    }

    var outputPoint: GridPoint? {
        switch kind {
        case .input, .high, .low: position
        case .output, .block: nil
        default: gridPoint(GridPoint(x: Self.length, y: 0))
        }
    }

    /// Every point a wire can connect to.
    var terminals: [GridPoint] {
        inputPoints + (outputPoint.map { [$0] } ?? []) + blockOutputPoints.map(\.point)
    }

    /// The area the symbol covers in its own frame, in grid units.
    var localBounds: (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        switch kind {
        case .input: (-3.2, 0, -0.8, 0.8)
        // 5V's bar and label above its terminal, GND's bars below.
        case .high: (-0.8, 0.8, -2.2, 0)
        case .low: (-0.8, 0.8, 0, 1.7)
        case .output: (0, 3.2, -0.8, 0.8)
        // The name sits under the box.
        case .block: (0, Double(blockLength), -1, Double(blockRows) + 1)
        default: (0, Double(Self.length), -bodyHalfHeight, bodyHalfHeight)
        }
    }

    /// The area the symbol covers on the sheet, in grid units.
    var bounds: CGRect {
        let b = localBounds
        let corners = [point(b.minX, b.minY), point(b.maxX, b.minY), point(b.maxX, b.maxY), point(b.minX, b.maxY)]
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }

    /// The same symbol with the terminals of `other` where the two share
    /// a terminal role (the same input slot, or the output), for dragging
    /// wires along when a gate moves, turns or gets another input count.
    func terminalMoves(to other: LogicGate) -> [GridPoint: GridPoint] {
        var moves: [GridPoint: GridPoint] = [:]
        let newInputs = Dictionary(uniqueKeysWithValues: zip(other.inputOffsets, other.inputPoints))
        for (offset, point) in zip(inputOffsets, inputPoints) {
            if let target = newInputs[offset] { moves[point] = target }
        }
        if let from = outputPoint, let to = other.outputPoint { moves[from] = to }
        let newOutputs = Dictionary(uniqueKeysWithValues: other.blockOutputPoints.map { ($0.row, $0.point) })
        for (row, point) in blockOutputPoints {
            if let target = newOutputs[row] { moves[point] = target }
        }
        return moves
    }
}

extension Circuit {
    /// The next free input name: A, B, … Z, then A1, B1, …
    func nextInputName() -> String {
        let used = Set(gates.filter { $0.kind == .input }.map(\.name))
        return Self.nextLetterName(avoiding: used, letters: (UnicodeScalar("A").value...UnicodeScalar("X").value))
    }

    /// The next free block name: U1, U2, … (like ICs on a schematic).
    func nextBlockName() -> String {
        let used = Set(gates.filter { $0.kind == .block }.map(\.name))
        var number = 1
        while used.contains("U\(number)") { number += 1 }
        return "U\(number)"
    }

    /// Puts a block's sub-diagram back into it. The block's terminals stay
    /// as they are set in its properties.
    mutating func setContents(_ inside: Circuit, ofBlock id: UUID) {
        guard let index = gates.firstIndex(where: { $0.id == id }) else { return }
        gates[index].subcircuit = inside
    }

    /// Makes a block's sub-diagram have exactly the block's terminals as its
    /// inputs and outputs: those of names the block no longer has go, and
    /// missing ones are added, inputs in a column on the left and outputs on
    /// the right, in the block's order. The terminals are set in the block's
    /// properties only.
    mutating func matchTerminals(of block: LogicGate) {
        let inputNames = Set(block.inputOffsets.map { block.blockPinName(.input($0)) })
        let outputNames = Set(block.blockOutputRows.map { block.blockPinName(.blockOutput($0)) })
        gates.removeAll { ($0.kind == .input && !inputNames.contains($0.name)) || ($0.kind == .output && !outputNames.contains($0.name)) }
        let inputs = Set(gates.filter { $0.kind == .input }.map(\.name))
        let outputs = Set(gates.filter { $0.kind == .output }.map(\.name))
        for row in block.inputOffsets {
            let name = block.blockPinName(.input(row))
            if !inputs.contains(name) {
                gates.append(LogicGate(kind: .input, position: GridPoint(x: 6, y: 4 + 2 * row), name: name))
            }
        }
        for row in block.blockOutputRows {
            let name = block.blockPinName(.blockOutput(row))
            if !outputs.contains(name) {
                gates.append(LogicGate(kind: .output, position: GridPoint(x: 34, y: 4 + 2 * row), name: name))
            }
        }
    }

    /// The next free output name: Y, Z, then Y1, Z1, …
    func nextOutputName() -> String {
        let used = Set(gates.filter { $0.kind == .output }.map(\.name))
        return Self.nextLetterName(avoiding: used, letters: (UnicodeScalar("Y").value...UnicodeScalar("Z").value))
    }

    private static func nextLetterName(avoiding used: Set<String>, letters range: ClosedRange<UInt32>) -> String {
        let letters = range.compactMap { UnicodeScalar($0).map(String.init) }
        var round = 0
        while true {
            let suffix = round == 0 ? "" : String(round)
            if let free = letters.first(where: { !used.contains($0 + suffix) }) { return free + suffix }
            round += 1
        }
    }
}

// MARK: - Boolean expressions

/// A Boolean expression, written with · for AND, + for OR, ⊕ for XOR and a
/// line over what is inverted (NOT).
nonisolated indirect enum BoolExpr: Hashable {
    case constant(Bool)
    case variable(String)
    case not(BoolExpr)
    case and([BoolExpr])
    case or([BoolExpr])
    case xor([BoolExpr])

    /// How tightly an operator binds, to know where parentheses are needed.
    var precedence: Int {
        switch self {
        case .or: 1
        case .xor: 2
        case .and: 3
        case .constant, .variable, .not: 4
        }
    }

    /// The expression with 1s and 0s (from 5V and GND) worked out: A·1 is A,
    /// A + 1 is 1, and so on.
    var simplifyingConstants: BoolExpr {
        func constants(_ items: [BoolExpr]) -> (values: [Bool], rest: [BoolExpr]) {
            let simplified = items.map(\.simplifyingConstants)
            var values: [Bool] = []
            var rest: [BoolExpr] = []
            for item in simplified {
                if case .constant(let value) = item { values.append(value) } else { rest.append(item) }
            }
            return (values, rest)
        }
        switch self {
        case .constant, .variable: return self
        case .not(let inner):
            let simplified = inner.simplifyingConstants
            if case .constant(let value) = simplified { return .constant(!value) }
            if case .not(let twice) = simplified { return twice }
            return .not(simplified)
        case .and(let items):
            let (values, rest) = constants(items)
            if values.contains(false) { return .constant(false) }
            return rest.isEmpty ? .constant(true) : rest.count == 1 ? rest[0] : .and(rest)
        case .or(let items):
            let (values, rest) = constants(items)
            if values.contains(true) { return .constant(true) }
            return rest.isEmpty ? .constant(false) : rest.count == 1 ? rest[0] : .or(rest)
        case .xor(let items):
            let (values, rest) = constants(items)
            let flips = values.filter { $0 }.count % 2 == 1
            let core: BoolExpr = rest.isEmpty ? .constant(false) : rest.count == 1 ? rest[0] : .xor(rest)
            return flips ? BoolExpr.not(core).simplifyingConstants : core
        }
    }

    /// The expression with each variable replaced by the expression given for
    /// it; `nil` if one of them has none.
    func substituting(_ values: [String: BoolExpr]) -> BoolExpr? {
        func all(_ items: [BoolExpr]) -> [BoolExpr]? {
            let replaced = items.map { $0.substituting(values) }
            return replaced.contains(where: { $0 == nil }) ? nil : replaced.compactMap { $0 }
        }
        switch self {
        case .constant: return self
        case .variable(let name): return values[name]
        case .not(let inner): return inner.substituting(values).map { .not($0) }
        case .and(let items): return all(items).map { .and($0) }
        case .or(let items): return all(items).map { .or($0) }
        case .xor(let items): return all(items).map { .xor($0) }
        }
    }

    /// Plain text with ¬ for NOT, e.g. "A·¬B + C".
    var text: String {
        switch self {
        case .constant(let value): value ? "1" : "0"
        case .variable(let name): name
        case .not(let inner):
            inner.precedence == 4 ? "¬" + inner.text : "¬(" + inner.text + ")"
        case .and(let items): Self.join(items, "·", self)
        case .or(let items): Self.join(items, " + ", self)
        case .xor(let items): Self.join(items, " ⊕ ", self)
        }
    }

    private static func join(_ items: [BoolExpr], _ separator: String, _ parent: BoolExpr) -> String {
        items.map { $0.needsParentheses(in: parent) ? "(" + $0.text + ")" : $0.text }
            .joined(separator: separator)
    }

    var isAtomic: Bool { precedence == 4 }

    /// Whether the expression needs parentheses as an operand of `parent`.
    func needsParentheses(in parent: BoolExpr) -> Bool {
        precedence < parent.precedence || (precedence == parent.precedence && !isAtomic)
    }

    /// HTML for the web page: inverted parts in `<span class="bar">`, drawn
    /// with a line over them.
    var html: String {
        switch self {
        case .constant(let value): value ? "1" : "0"
        case .variable(let name): Self.escape(name)
        case .not(let inner): "<span class=\"bar\">\(inner.html)</span>"
        case .and(let items): Self.joinHTML(items, "·", self)
        case .or(let items): Self.joinHTML(items, " + ", self)
        case .xor(let items): Self.joinHTML(items, " ⊕ ", self)
        }
    }

    private static func joinHTML(_ items: [BoolExpr], _ separator: String, _ parent: BoolExpr) -> String {
        items.map { $0.needsParentheses(in: parent) ? "(" + $0.html + ")" : $0.html }
            .joined(separator: separator)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The parts of the expression in reading order, for drawing it: each
    /// with how many lines lie over it.
    struct Piece: Hashable {
        var text: String
        /// The NOTs this piece is under, outermost first, by an id that is
        /// the same for every piece under the same NOT.
        var bars: [Int]
    }

    var pieces: [Piece] {
        var counter = 0
        var result: [Piece] = []
        func walk(_ expr: BoolExpr, bars: [Int]) {
            func add(_ text: String) { result.append(Piece(text: text, bars: bars)) }
            func items(_ list: [BoolExpr], _ separator: String) {
                for (index, item) in list.enumerated() {
                    if index > 0 { add(separator) }
                    let needsParentheses = item.needsParentheses(in: expr)
                    if needsParentheses { add("(") }
                    walk(item, bars: bars)
                    if needsParentheses { add(")") }
                }
            }
            switch expr {
            case .constant(let value): add(value ? "1" : "0")
            case .variable(let name): add(name)
            case .not(let inner):
                counter += 1
                walk(inner, bars: bars + [counter])
            case .and(let list): items(list, "·")
            case .or(let list): items(list, " + ")
            case .xor(let list): items(list, " ⊕ ")
            }
        }
        walk(self, bars: [])
        return result
    }
}

// MARK: - The logic of a drawn circuit

/// The nets of a digital sheet and what drives them, for simulating it and
/// making its truth table. Wires connect like on an analog sheet: at their
/// ends, and where an end lands on another wire.
nonisolated struct LogicNetwork {
    private enum Driver: Hashable {
        case input(String, inverted: Bool)
        /// 5V (1) or GND (0); every flag of the same kind is the same signal.
        case constant(Bool)
        case gate(Int)
        /// A block's output: the block's index and the output's row.
        case blockOutput(Int, row: Int)

        /// The gate or block the signal comes from.
        var gateIndex: Int? {
            switch self {
            case .input, .constant: nil
            case .gate(let index), .blockOutput(let index, _): index
            }
        }
    }

    let gates: [LogicGate]
    /// The truth table's column order chosen by the user (`Circuit.logicColumnOrder`).
    let columnOrder: [String]
    private(set) var netOf: [GridPoint: Int] = [:]
    private(set) var netCount = 0
    /// For each gate, the net of each of its inputs.
    private var inputNets: [[Int]] = []
    private var drivers: [Int: Driver] = [:]
    /// Nets driven by more than one output.
    private var conflicts = Set<Int>()
    /// Whether some gate's output feeds back into its own input.
    private(set) var hasLoop = false
    /// The insides of the blocks that have one, by the block's index.
    private var blockNetworks: [Int: LogicNetwork] = [:]
    /// What's wrong with the drawing, in Danish, for the truth table.
    private(set) var issues: [String] = []

    /// The input names: the truth table's variables, the first the most
    /// significant bit. In the order the user chose, otherwise alphabetical.
    var variables: [String] {
        Array(Set(gates.filter { $0.kind == .input }.map(\.name))).sorted(by: columnPrecedes)
    }

    /// The outputs, in the order the user chose, otherwise alphabetical.
    var outputs: [LogicGate] {
        gates.filter { $0.kind == .output }.sorted { columnPrecedes($0.name, $1.name) }
    }

    /// Names in the chosen order come first, in that order; the rest alphabetically.
    private func columnPrecedes(_ a: String, _ b: String) -> Bool {
        switch (columnOrder.firstIndex(of: a), columnOrder.firstIndex(of: b)) {
        case let (i?, j?): i < j
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): Self.nameOrder(a, b)
        }
    }

    /// A before B, and A2 before A10.
    static func nameOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    init(_ circuit: Circuit) {
        gates = circuit.gates
        columnOrder = circuit.logicColumnOrder ?? []
        var parent: [GridPoint: GridPoint] = [:]
        func find(_ point: GridPoint) -> GridPoint {
            var root = point
            while let next = parent[root], next != root { root = next }
            return root
        }
        func union(_ a: GridPoint, _ b: GridPoint) {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let rootA = find(a), rootB = find(b)
            if rootA != rootB { parent[rootA] = rootB }
        }

        var connectionPoints = Set<GridPoint>()
        for wire in circuit.wires {
            connectionPoints.insert(wire.start)
            connectionPoints.insert(wire.end)
        }
        for gate in gates { connectionPoints.formUnion(gate.terminals) }
        for point in connectionPoints { parent[point] = point }
        for wire in circuit.wires {
            for (a, b) in wire.segments {
                var onSegment = [a, b] + connectionPoints.filter { Circuit.point($0, isInteriorOf: a, b) }
                onSegment.sort { ($0.x, $0.y) < ($1.x, $1.y) }
                for (p, q) in zip(onSegment, onSegment.dropFirst()) where p != q { union(p, q) }
            }
        }

        var netOfRoot: [GridPoint: Int] = [:]
        for point in parent.keys {
            let root = find(point)
            if netOfRoot[root] == nil {
                netOfRoot[root] = netCount
                netCount += 1
            }
            netOf[point] = netOfRoot[root]
        }

        for (index, gate) in gates.enumerated() {
            inputNets.append(gate.inputPoints.map { netOf[$0] ?? -1 })
            if let subcircuit = gate.subcircuit, gate.kind == .block {
                blockNetworks[index] = LogicNetwork(subcircuit)
            }
            var outputs: [(net: Int?, driver: Driver)] = gate.blockOutputPoints.map { (netOf[$0.point], .blockOutput(index, row: $0.row)) }
            if let output = gate.outputPoint {
                let driver: Driver = switch gate.kind {
                case .input: .input(gate.name, inverted: gate.isInverted(.output))
                case .high, .low: .constant(gate.kind == .high)
                default: .gate(index)
                }
                outputs.append((netOf[output], driver))
            }
            for case let (net?, driver) in outputs {
                if let existing = drivers[net], existing != driver {
                    conflicts.insert(net)
                } else {
                    drivers[net] = driver
                }
            }
        }
        hasLoop = findsLoop()
        issues = describeIssues()
    }

    /// Whether following the nets from some gate leads back to it.
    private func findsLoop() -> Bool {
        var state: [Int: Int] = [:]
        func visit(_ index: Int) -> Bool {
            if state[index] == 1 { return true }
            if state[index] == 2 { return false }
            state[index] = 1
            for net in inputNets[index] {
                if let source = drivers[net]?.gateIndex, visit(source) { return true }
            }
            state[index] = 2
            return false
        }
        return gates.indices.contains { visit($0) }
    }

    private func describeIssues() -> [String] {
        var issues: [String] = []
        if !conflicts.isEmpty {
            issues.append("To udgange er forbundet med hinanden. En ledning må kun få sit signal fra én gate eller indgang.")
        }
        if hasLoop {
            issues.append("Kredsløbet har en tilbagekobling (en gate får sit eget signal tilbage). Sandhedstabellen kan kun laves for kredsløb uden løkker.")
        }
        var loose: [String: Int] = [:]
        for (index, gate) in gates.enumerated() where gate.kind != .input {
            let unconnected = inputNets[index].filter { drivers[$0] == nil }.count
            guard unconnected > 0 else { continue }
            let what = switch gate.kind {
            case .output: "Udgang \(gate.name)"
            case .block: "Blok \(gate.name)"
            default: gate.kind.shortName + "-gate"
            }
            loose[what, default: 0] += unconnected
        }
        for (index, gate) in gates.enumerated() where gate.kind == .block && !gate.blockOutputRows.isEmpty {
            if blockNetworks[index]?.outputs.isEmpty ?? true {
                issues.append("Blok \(gate.name) har intet indhold endnu, så dens udgange har ingen værdi.")
            }
        }
        for (what, count) in loose.sorted(by: { $0.key < $1.key }) {
            issues.append(count == 1
                ? "\(what) har en indgang, der ikke får noget signal."
                : "\(what) har \(count) indgange, der ikke får noget signal.")
        }
        return issues
    }

    /// The value on every net for the given input values (by name); nets
    /// without a value (nothing drives them, or they're in a loop) are left out.
    func evaluate(_ values: [String: Bool]) -> [Int: Bool] {
        var result: [Int: Bool] = [:]
        var visiting = Set<Int>()
        var done = Set<Int>()
        func value(_ net: Int) -> Bool? {
            if let known = result[net] { return known }
            guard !done.contains(net), !visiting.contains(net), !conflicts.contains(net), let driver = drivers[net] else { return nil }
            visiting.insert(net)
            defer {
                visiting.remove(net)
                done.insert(net)
            }
            let computed: Bool?
            switch driver {
            case .input(let name, let inverted):
                computed = (values[name] ?? false) != inverted
            case .constant(let value):
                computed = value
            case .gate(let index):
                let gate = gates[index]
                let inputs = zip(inputNets[index], gate.inputOffsets).map { net, offset in
                    value(net).map { $0 != gate.isInverted(.input(offset)) }
                }
                computed = inputs.contains(where: { $0 == nil })
                    ? nil
                    : gate.kind.evaluate(inputs.compactMap { $0 }) != gate.isInverted(.output)
            case .blockOutput(let index, let row):
                let gate = gates[index]
                // The block's inputs, by name, as its sub-diagram's inputs.
                var inside: [String: Bool] = [:]
                var complete = true
                for (net, offset) in zip(inputNets[index], gate.inputOffsets) {
                    guard let bit = value(net) else {
                        complete = false
                        break
                    }
                    inside[gate.blockPinName(.input(offset))] = bit != gate.isInverted(.input(offset))
                }
                computed = complete
                    ? blockNetworks[index]?.output(named: gate.blockPinName(.blockOutput(row)), for: inside)
                        .map { $0 != gate.isInverted(.blockOutput(row)) }
                    : nil
            }
            if let computed { result[net] = computed }
            return computed
        }
        for net in 0..<netCount { _ = value(net) }
        return result
    }

    /// The value of the output with this name for the given input values
    /// (by name), as a block uses its sub-diagram.
    func output(named name: String, for inputs: [String: Bool]) -> Bool? {
        guard let output = outputs.first(where: { $0.name == name }) else { return nil }
        return value(of: output, in: evaluate(inputs))
    }

    /// The value reaching an output for the given input values.
    func value(of output: LogicGate, in values: [Int: Bool]) -> Bool? {
        output.inputPoints.first.flatMap { netOf[$0] }.flatMap { values[$0] }.map { $0 != output.isInverted(.input(0)) }
    }

    /// The most inputs a truth table is made for (256 rows).
    static let maxVariables = 8

    /// The truth table: a row for every combination of the inputs, the
    /// first input as the most significant bit.
    func truthTable() -> LogicTruthTable {
        let variables = self.variables
        let outputs = self.outputs
        guard variables.count <= Self.maxVariables else {
            return LogicTruthTable(variables: variables, outputs: [])
        }
        let rows = 1 << variables.count
        var columns = outputs.map { LogicTruthTable.Column(name: $0.name, values: []) }
        for row in 0..<rows {
            var assignment: [String: Bool] = [:]
            for (index, name) in variables.enumerated() {
                assignment[name] = row >> (variables.count - 1 - index) & 1 == 1
            }
            let values = evaluate(assignment)
            for (index, output) in outputs.enumerated() {
                columns[index].values.append(value(of: output, in: values))
            }
        }
        return LogicTruthTable(variables: variables, outputs: columns)
    }

    /// The expression an output computes, following the drawing gate by gate.
    func expression(for output: LogicGate) -> BoolExpr? {
        guard let net = output.inputPoints.first.flatMap({ netOf[$0] }) else { return nil }
        func inverted(_ expr: BoolExpr, _ invert: Bool) -> BoolExpr {
            guard invert else { return expr }
            if case .not(let inner) = expr { return inner }
            return .not(expr)
        }
        var visiting = Set<Int>()
        func expression(_ net: Int) -> BoolExpr? {
            guard !conflicts.contains(net), let driver = drivers[net] else { return nil }
            switch driver {
            case .input(let name, let invert):
                return inverted(.variable(name), invert)
            case .constant(let value):
                return .constant(value)
            case .gate(let index):
                guard !visiting.contains(index) else { return nil }
                visiting.insert(index)
                defer { visiting.remove(index) }
                let gate = gates[index]
                let inputs = zip(inputNets[index], gate.inputOffsets).map { net, offset in
                    expression(net).map { inverted($0, gate.isInverted(.input(offset))) }
                }
                guard !inputs.contains(where: { $0 == nil }) else { return nil }
                let items = inputs.compactMap { $0 }
                let result: BoolExpr? = switch gate.kind {
                case .and: .and(items)
                case .or: .or(items)
                case .xor: .xor(items)
                case .nand: .not(.and(items))
                case .nor: .not(.or(items))
                case .xnor: .not(.xor(items))
                case .not: items.first.map { .not($0) }
                case .input, .output: items.first
                case .block: nil
                case .high: .constant(true)
                case .low: .constant(false)
                }
                return result.map { inverted($0, gate.isInverted(.output)) }
            case .blockOutput(let index, let row):
                // The sub-diagram's expression for the output, with the
                // expressions reaching the block's inputs put in.
                guard !visiting.contains(index), let inside = blockNetworks[index] else { return nil }
                visiting.insert(index)
                defer { visiting.remove(index) }
                let gate = gates[index]
                var inputs: [String: BoolExpr] = [:]
                for (net, offset) in zip(inputNets[index], gate.inputOffsets) {
                    guard let input = expression(net) else { return nil }
                    inputs[gate.blockPinName(.input(offset))] = inverted(input, gate.isInverted(.input(offset)))
                }
                guard let output = inside.outputs.first(where: { $0.name == gate.blockPinName(.blockOutput(row)) }),
                      let result = inside.expression(for: output)?.substituting(inputs) else { return nil }
                return inverted(result, gate.isInverted(.blockOutput(row)))
            }
        }
        return expression(net).map { inverted($0, output.isInverted(.input(0))).simplifyingConstants }
    }
}

/// A truth table: the inputs, and for each output its value in every row
/// (`nil` where it can't be worked out).
nonisolated struct LogicTruthTable: Hashable {
    struct Column: Hashable {
        var name: String
        var values: [Bool?]
    }

    var variables: [String]
    var outputs: [Column]

    var rowCount: Int { 1 << variables.count }

    /// The value of input `index` in a row.
    func bit(row: Int, variable index: Int) -> Bool {
        row >> (variables.count - 1 - index) & 1 == 1
    }
}

/// Which rows of a truth table are shown, and the number (m) each is given.
/// With a range like [0, 15] the rows are numbered as usual and only those
/// inside it are shown; a range reaching below 0, like [−8, 7], reads the
/// inputs as a signed number (two's complement), in order from the lowest.
nonisolated enum RowNumbering {
    /// Reads "[-8,7]", "-8..7", "-8;7", "−8 til 7" and the like. `nil` if it isn't a range.
    static func parse(_ text: String) -> ClosedRange<Int>? {
        let cleaned = text.replacingOccurrences(of: "−", with: "-")
        var numbers: [Int] = []
        var current = ""
        func flush() {
            if let number = Int(current) { numbers.append(number) }
            current = ""
        }
        for character in cleaned {
            if character.isNumber {
                current.append(character)
            } else if character == "-", current.isEmpty || current == "-" {
                // A minus sign starts a number; after digits it separates two ("0-16").
                current = "-"
            } else if character == "-" {
                flush()
            } else {
                flush()
            }
        }
        flush()
        guard numbers.count == 2 else { return nil }
        return min(numbers[0], numbers[1])...max(numbers[0], numbers[1])
    }

    /// The number of a row: its bits read as an unsigned or (`signed`) a
    /// two's complement number.
    static func number(row: Int, variables count: Int, signed: Bool) -> Int {
        signed && count > 0 && row >= 1 << (count - 1) ? row - (1 << count) : row
    }

    /// The rows to show, in order, each with its number.
    static func rows(variables count: Int, range: ClosedRange<Int>?) -> [(row: Int, number: Int)] {
        let all = (0..<(1 << count)).map { ($0, $0) }
        guard let range else { return all }
        let signed = range.lowerBound < 0
        return (0..<(1 << count))
            .map { (row: $0, number: number(row: $0, variables: count, signed: signed)) }
            .filter { range.contains($0.number) }
            .sorted { $0.number < $1.number }
    }
}
