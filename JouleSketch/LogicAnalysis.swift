import Foundation

// MARK: - Truth table values

/// A value in the truth table calculator: 0, 1, or "don't care" (X), which
/// may be either, whichever gives the simpler expression.
nonisolated enum TruthValue: String, Codable, Hashable {
    case zero = "0"
    case one = "1"
    case dontCare = "X"

    /// The value a click on the cell gives: 0 → 1 → X → 0.
    var next: TruthValue {
        switch self {
        case .zero: .one
        case .one: .dontCare
        case .dontCare: .zero
        }
    }
}

/// How the minimized expression is written.
nonisolated enum LogicForm: String, Codable, CaseIterable, Identifiable {
    /// OR of AND terms, made from the ones.
    case sumOfProducts
    /// AND of OR terms, made from the zeros.
    case productOfSums

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sumOfProducts: "Sum af produkter (SOP)"
        case .productOfSums: "Produkt af summer (POS)"
        }
    }

    var shortName: String {
        switch self {
        case .sumOfProducts: "SOP (ettaller)"
        case .productOfSums: "POS (nuller)"
        }
    }
}

// MARK: - Minimizing

/// A group of truth table rows that share the values of some variables: the
/// variables whose bit is set in `mask` change within the group and drop out.
/// Row (minterm) numbers have the first variable as the most significant bit.
nonisolated struct Implicant: Hashable {
    var value: Int
    var mask: Int

    init(value: Int, mask: Int) {
        self.value = value & ~mask
        self.mask = mask
    }

    func covers(_ row: Int) -> Bool {
        row & ~mask == value
    }

    func rows(variables count: Int) -> [Int] {
        (0..<(1 << count)).filter(covers)
    }

    /// The variables that keep their value in the group, by index, with that value.
    func fixed(variables count: Int) -> [(index: Int, isOne: Bool)] {
        (0..<count).compactMap { index in
            let bit = 1 << (count - 1 - index)
            return mask & bit == 0 ? (index, value & bit != 0) : nil
        }
    }

    /// The variables that change in the group and drop out.
    func changing(variables count: Int) -> [Int] {
        (0..<count).filter { mask & (1 << (count - 1 - $0)) != 0 }
    }
}

/// Finds a smallest sum of products (or product of sums) with the
/// Quine–McCluskey method: the prime implicants, then the fewest of them
/// that cover what must be covered.
nonisolated enum LogicMinimizer {
    /// The largest groups that can be made from `rows` (ones and don't cares).
    static func primeImplicants(of rows: Set<Int>, variables count: Int) -> [Implicant] {
        var current = Set(rows.map { Implicant(value: $0, mask: 0) })
        var primes = Set<Implicant>()
        while !current.isEmpty {
            var next = Set<Implicant>()
            var combined = Set<Implicant>()
            for implicant in current {
                for index in 0..<count {
                    let bit = 1 << index
                    guard implicant.mask & bit == 0 else { continue }
                    let partner = Implicant(value: implicant.value ^ bit, mask: implicant.mask)
                    if current.contains(partner) {
                        next.insert(Implicant(value: implicant.value, mask: implicant.mask | bit))
                        combined.insert(implicant)
                        combined.insert(partner)
                    }
                }
            }
            primes.formUnion(current.subtracting(combined))
            current = next
        }
        return primes.sorted { ($0.rows(variables: count).first ?? 0, $0.mask) < ($1.rows(variables: count).first ?? 0, $1.mask) }
    }

    /// The fewest prime implicants covering every row in `required`, with as
    /// few variables as possible among those. Essential ones (the only one
    /// covering some row) are always part of it.
    static func cover(_ required: Set<Int>, with primes: [Implicant], variables count: Int) -> (chosen: [Implicant], essential: Set<Implicant>) {
        let useful = primes.filter { prime in required.contains(where: prime.covers) }
        var chosen: [Implicant] = []
        var essential = Set<Implicant>()
        for row in required.sorted() {
            let covering = useful.filter { $0.covers(row) }
            if covering.count == 1, let only = covering.first, !essential.contains(only) {
                essential.insert(only)
                chosen.append(only)
            }
        }
        var uncovered = required.filter { row in !chosen.contains { $0.covers(row) } }
        let candidates = useful.filter { candidate in !essential.contains(candidate) && uncovered.contains(where: candidate.covers) }
        func literals(_ list: [Implicant]) -> Int {
            list.reduce(0) { $0 + count - $1.mask.nonzeroBitCount }
        }

        if !uncovered.isEmpty, candidates.count <= 16 {
            // Every combination, smallest first.
            search: for size in 1...max(1, candidates.count) {
                var best: [Implicant]?
                func pick(from start: Int, _ picked: [Implicant]) {
                    if picked.count == size {
                        guard uncovered.allSatisfy({ row in picked.contains { $0.covers(row) } }) else { return }
                        if best == nil || literals(picked) < literals(best ?? []) { best = picked }
                        return
                    }
                    guard start < candidates.count else { return }
                    for index in start..<candidates.count {
                        pick(from: index + 1, picked + [candidates[index]])
                    }
                }
                pick(from: 0, [])
                if let best {
                    chosen += best
                    break search
                }
            }
        } else {
            // Too many to try: take the one covering most, again and again.
            while !uncovered.isEmpty {
                guard let next = candidates.max(by: { a, b in
                    let coverA = uncovered.filter(a.covers).count, coverB = uncovered.filter(b.covers).count
                    return coverA != coverB ? coverA < coverB : a.mask.nonzeroBitCount < b.mask.nonzeroBitCount
                }) else { break }
                chosen.append(next)
                uncovered = uncovered.filter { !next.covers($0) }
            }
        }
        chosen.sort { ($0.rows(variables: count).first ?? 0) < ($1.rows(variables: count).first ?? 0) }
        return (chosen, essential)
    }
}

// MARK: - Karnaugh maps

/// A Karnaugh map for 2 to 4 variables: the first half of the variables
/// down the side, the rest across the top, both in Gray code so
/// neighboring cells differ in one variable only.
nonisolated struct KarnaughMap: Hashable {
    /// A block of cells: `rows` × `columns` from (`row`, `column`).
    struct Block: Hashable {
        var row: Int
        var column: Int
        var rows: Int
        var columns: Int
    }

    let rowVariables: [String]
    let columnVariables: [String]
    let rowLabels: [String]
    let columnLabels: [String]
    /// The truth table row (minterm) of each cell, by row and column.
    let cells: [[Int]]
    private let variableCount: Int

    static let variableRange = 2...4

    init?(variables: [String]) {
        guard Self.variableRange.contains(variables.count) else { return nil }
        variableCount = variables.count
        let rowBits = variables.count / 2
        let columnBits = variables.count - rowBits
        rowVariables = Array(variables.prefix(rowBits))
        columnVariables = Array(variables.suffix(columnBits))
        let rowCodes = Self.grayCodes(bits: rowBits)
        let columnCodes = Self.grayCodes(bits: columnBits)
        rowLabels = rowCodes.map { Self.binary($0, bits: rowBits) }
        columnLabels = columnCodes.map { Self.binary($0, bits: columnBits) }
        cells = rowCodes.map { row in columnCodes.map { column in row << columnBits | column } }
    }

    static func grayCodes(bits: Int) -> [Int] {
        bits == 2 ? [0, 1, 3, 2] : [0, 1]
    }

    static func binary(_ value: Int, bits: Int) -> String {
        (0..<bits).reversed().map { value >> $0 & 1 == 1 ? "1" : "0" }.joined()
    }

    /// The rectangles a group covers. A group running over the edge of the
    /// map is split in two (or four, in the corners).
    func blocks(for implicant: Implicant) -> [Block] {
        let rows = cells.indices.filter { row in cells[row].contains(where: implicant.covers) }
        let columns = (cells.first ?? []).indices.filter { column in cells.contains { implicant.covers($0[column]) } }
        var blocks: [Block] = []
        for rowRun in Self.runs(rows) {
            for columnRun in Self.runs(columns) {
                blocks.append(Block(row: rowRun.start, column: columnRun.start, rows: rowRun.count, columns: columnRun.count))
            }
        }
        return blocks
    }

    private static func runs(_ indices: [Int]) -> [(start: Int, count: Int)] {
        var runs: [(start: Int, count: Int)] = []
        for index in indices {
            if let last = runs.last, last.start + last.count == index {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((index, 1))
            }
        }
        return runs
    }
}

// MARK: - Analysis

/// One step of the explanation: text (which may mark words as **bold**),
/// and maybe an expression after it, e.g. the term a group gives.
nonisolated struct LogicStep: Hashable {
    var text: String
    var expression: BoolExpr?
    /// Written before the expression, e.g. "Y = ".
    var prefix = ""
    /// The group this step is about, for its color.
    var group: Int?
}

/// How many of one kind of gate a circuit needs.
nonisolated struct GateCount: Hashable {
    var kind: GateKind
    var inputs: Int
    var count: Int
    /// How many of their inputs (in all) have an inverting circle.
    var invertedInputs = 0

    var text: String {
        guard kind != .not else { return "\(count) × NOT" }
        let circles = switch invertedInputs {
        case 0: ""
        case 1: ", heraf 1 inverteret (lille cirkel)"
        default: ", heraf \(invertedInputs) inverterede (små cirkler)"
        }
        return "\(count) × \(kind.shortName) med \(inputs) indgange" + circles
    }
}

/// A truth table column worked out: the smallest expression for it, the
/// groups behind it on the Karnaugh map, the steps there, and the gates needed.
nonisolated struct LogicAnalysis: Hashable {
    struct Group: Hashable {
        var implicant: Implicant
        var rows: [Int]
        var term: BoolExpr
        var isEssential: Bool
        /// A row only this group covers, which makes it essential.
        var onlyRow: Int?
    }

    let variables: [String]
    let output: String
    let form: LogicForm
    let values: [TruthValue]
    let groups: [Group]
    let expression: BoolExpr
    let map: KarnaughMap?
    private(set) var steps: [LogicStep] = []
    private(set) var gateCounts: [GateCount] = []
    /// How the circuit for the expression is drawn; `nil` when the output is constant.
    private(set) var plan: LogicPlan?

    var isConstant: Bool {
        if case .constant = expression { return true }
        return false
    }

    init(variables: [String], output: String, values: [TruthValue], form: LogicForm) {
        self.variables = variables
        self.output = output
        self.form = form
        self.values = values
        let count = variables.count
        let isSOP = form == .sumOfProducts
        let target: TruthValue = isSOP ? .one : .zero
        let required = Set(values.indices.filter { values[$0] == target })
        let allowed = required.union(values.indices.filter { values[$0] == .dontCare })
        map = KarnaughMap(variables: variables)

        let primes = LogicMinimizer.primeImplicants(of: allowed, variables: count)
        let (chosen, essential) = required.isEmpty ? ([], []) : LogicMinimizer.cover(required, with: primes, variables: count)

        func literal(_ index: Int, isOne: Bool) -> BoolExpr {
            // SOP: a 1 is the variable itself; POS: a 0 is.
            isOne == isSOP ? .variable(variables[index]) : .not(.variable(variables[index]))
        }
        groups = chosen.map { implicant in
            let literals = implicant.fixed(variables: count).map { literal($0.index, isOne: $0.isOne) }
            let term: BoolExpr = switch literals.count {
            case 0: .constant(isSOP)
            case 1: literals[0]
            default: isSOP ? .and(literals) : .or(literals)
            }
            let onlyRow = required.sorted().first { row in implicant.covers(row) && primes.filter { $0.covers(row) }.count == 1 }
            return Group(implicant: implicant, rows: implicant.rows(variables: count), term: term, isEssential: essential.contains(implicant), onlyRow: onlyRow)
        }

        if groups.isEmpty {
            expression = .constant(!isSOP)
        } else if groups.contains(where: { $0.implicant.mask == (1 << count) - 1 }) {
            expression = .constant(isSOP)
        } else if groups.count == 1 {
            expression = groups[0].term
        } else {
            expression = isSOP ? .or(groups.map(\.term)) : .and(groups.map(\.term))
        }
        steps = makeSteps(required: required)
        let literals = groups.map { group in
            group.implicant.fixed(variables: count).map { LogicLiteral(index: $0.index, inverted: $0.isOne != isSOP) }
        }
        plan = Self.makePlan(groups: groups, literals: literals, values: values, variables: count, form: form, isConstant: isConstant)
        gateCounts = Self.countGates(plan)
    }

    /// "m(1, 3, 5)".
    private static func rowList(_ rows: [Int], letter: String) -> String {
        "\(letter)(\(rows.map(String.init).joined(separator: ", ")))"
    }

    /// "A, B og C".
    static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " og " + last
    }

    private func makeSteps(required: Set<Int>) -> [LogicStep] {
        let isSOP = form == .sumOfProducts
        let count = variables.count
        let dontCares = values.indices.filter { values[$0] == .dontCare }
        let letter = isSOP ? "m" : "M"
        let digit = isSOP ? "ettallerne" : "nullerne"
        var steps: [LogicStep] = []

        if required.isEmpty || isConstant {
            let value = isConstant ? expression : .constant(!isSOP)
            steps.append(LogicStep(
                text: "\(output) har samme værdi i alle rækker (bortset fra X), så den afhænger ikke af indgangene, og der skal ingen gates til.",
                expression: value, prefix: "\(output) = "
            ))
            return steps
        }

        var first = isSOP
            ? "**1. Find ettallerne.** \(output) er 1 i rækkerne \(Self.rowList(required.sorted(), letter: "m")), dvs. \(output) = Σ\(Self.rowList(required.sorted(), letter: "m"))."
            : "**1. Find nullerne.** \(output) er 0 i rækkerne \(Self.rowList(required.sorted(), letter: "M")), dvs. \(output) = Π\(Self.rowList(required.sorted(), letter: "M"))."
        if !dontCares.isEmpty {
            first += " Rækkerne med X (don't care), \(Self.rowList(dontCares, letter: "d")), må gerne komme med i en gruppe, men skal ikke."
        }
        steps.append(LogicStep(text: first))

        if let map {
            let rows = Self.list(map.rowVariables), columns = Self.list(map.columnVariables)
            steps.append(LogicStep(text: "**2. Skriv dem i Karnaugh-kortet.** \(rows) står ned ad siden og \(columns) hen over toppen, i Gray-kode (\(count == 2 ? "0, 1" : "00, 01, 11, 10")), så to nabofelter – også hen over kanten – kun er forskellige i én variabel."))
            steps.append(LogicStep(text: "**3. Ring \(digit) ind i så få og så store grupper som muligt.** En gruppe er et rektangel med 1, 2, 4 eller 8 felter og må gå hen over kanten. En gruppe med 2 felter fjerner én variabel, 4 felter to og 8 felter tre."))
        } else {
            steps.append(LogicStep(text: "**2. Slå rækkerne sammen (Quine–McCluskey).** Med \(count) variable er et Karnaugh-kort upraktisk. To rækker, der kun er forskellige i én variabel, slås sammen, så den variabel forsvinder, og det gentages, til intet kan slås sammen mere."))
            steps.append(LogicStep(text: "**3. Vælg så få af de største grupper som muligt**, så alle \(digit) er med."))
        }

        for (index, group) in groups.enumerated() {
            let changing = group.implicant.changing(variables: count).map { variables[$0] }
            let fixed = group.implicant.fixed(variables: count).map { "\(variables[$0.index]) = \($0.isOne ? 1 : 0)" }
            var text = "Gruppe \(index + 1): \(Self.rowList(group.rows, letter: letter))."
            if !changing.isEmpty {
                text += " \(Self.list(changing)) skifter værdi og forsvinder."
            }
            if !fixed.isEmpty {
                text += " \(Self.list(fixed)) er fælles"
                text += isSOP
                    ? " – en variabel, der er 1, skrives som den er, og en, der er 0, med streg over:"
                    : " – i POS skrives en variabel, der er 0, som den er, og en, der er 1, med streg over, og de lægges sammen:"
            }
            if group.isEssential, let row = group.onlyRow {
                text = text.replacingOccurrences(of: "Gruppe \(index + 1):", with: "Gruppe \(index + 1) (nødvendig – \(letter)\(row) ligger kun i den):")
            }
            steps.append(LogicStep(text: text, expression: group.term, group: index))
        }

        steps.append(LogicStep(
            text: isSOP
                ? (groups.count == 1 ? "**4. Gruppen giver hele udtrykket:**" : "**4. Læg grupperne sammen med OR:**")
                : (groups.count == 1 ? "**4. Gruppen giver hele udtrykket:**" : "**4. Gang grupperne sammen med AND:**"),
            expression: expression, prefix: "\(output) = "
        ))
        return steps
    }

    /// The literals of a group: variable index and whether it's inverted.
    func literals(of group: Group) -> [(index: Int, inverted: Bool)] {
        let isSOP = form == .sumOfProducts
        return group.implicant.fixed(variables: variables.count).map { ($0.index, $0.isOne != isSOP) }
    }

    /// The gate kind of the first level (one per group) and the second
    /// (combining the groups).
    var levelKinds: (first: GateKind, second: GateKind) {
        form == .sumOfProducts ? (.and, .or) : (.or, .and)
    }

    /// How the circuit is drawn: the simplest of one wire, one gate
    /// (AND, OR, NAND, NOR, XOR or XNOR) or two levels of gates, with small
    /// circles on the gate inputs instead of NOT gates.
    private static func makePlan(groups: [Group], literals: [[LogicLiteral]], values: [TruthValue], variables count: Int, form: LogicForm, isConstant: Bool) -> LogicPlan? {
        guard !isConstant, !groups.isEmpty else { return nil }
        let isSOP = form == .sumOfProducts
        if literals.count == 1 {
            let term = literals[0]
            return term.count == 1 ? .wire(term[0]) : singleGate(isSOP ? .and : .or, term)
        }
        if let xor = xorPlan(values: values, variables: count) { return xor }
        if literals.allSatisfy({ $0.count == 1 }) {
            return singleGate(isSOP ? .or : .and, literals.map { $0[0] })
        }
        return .twoLevel(first: isSOP ? .and : .or, second: isSOP ? .or : .and, terms: literals)
    }

    /// One AND or OR gate, or the NOR or NAND with the opposite inputs
    /// (De Morgan) if that needs fewer circles: A + B̄ + C̄ is a NAND of Ā, B and C.
    private static func singleGate(_ kind: GateKind, _ literals: [LogicLiteral]) -> LogicPlan {
        let literals = literals.sorted { $0.index < $1.index }
        let flipped = literals.map { LogicLiteral(index: $0.index, inverted: !$0.inverted) }
        let circles = literals.filter(\.inverted).count
        guard flipped.filter(\.inverted).count < circles else { return .gate(kind, literals) }
        return .gate(kind == .and ? .nor : .nand, flipped)
    }

    /// One XOR or XNOR gate, if the output is 1 exactly when an odd (or even)
    /// number of some two or more inputs are 1.
    private static func xorPlan(values: [TruthValue], variables count: Int) -> LogicPlan? {
        guard count >= 2 else { return nil }
        let masks = (1..<(1 << count)).filter { $0.nonzeroBitCount >= 2 }.sorted { $0.nonzeroBitCount < $1.nonzeroBitCount }
        for mask in masks {
            for inverted in [false, true] {
                let matches = values.indices.allSatisfy { row in
                    values[row] == .dontCare || (((row & mask).nonzeroBitCount % 2 == 1) != inverted) == (values[row] == .one)
                }
                guard matches else { continue }
                let inputs = (0..<count).filter { mask & (1 << (count - 1 - $0)) != 0 }.map { LogicLiteral(index: $0, inverted: false) }
                return .gate(inverted ? .xnor : .xor, inputs)
            }
        }
        return nil
    }

    private static func countGates(_ plan: LogicPlan?) -> [GateCount] {
        switch plan {
        case nil: []
        case .wire(let literal):
            literal.inverted ? [GateCount(kind: .not, inputs: 1, count: 1)] : []
        case .gate(let kind, let inputs):
            [GateCount(kind: kind, inputs: inputs.count, count: 1, invertedInputs: inputs.filter(\.inverted).count)]
        case .twoLevel(let first, let second, let terms):
            {
                var counts: [GateCount] = []
                var firstLevel: [Int: (count: Int, inverted: Int)] = [:]
                for term in terms where term.count >= 2 {
                    let entry = firstLevel[term.count] ?? (0, 0)
                    firstLevel[term.count] = (entry.count + 1, entry.inverted + term.filter(\.inverted).count)
                }
                for (inputs, entry) in firstLevel.sorted(by: { $0.key < $1.key }) {
                    counts.append(GateCount(kind: first, inputs: inputs, count: entry.count, invertedInputs: entry.inverted))
                }
                let direct = terms.filter { $0.count == 1 && $0[0].inverted }.count
                counts.append(GateCount(kind: second, inputs: terms.count, count: 1, invertedInputs: direct))
                return counts
            }()
        }
    }

    /// The expression the drawn circuit computes, gate by gate.
    var drawnExpression: BoolExpr? {
        func literal(_ literal: LogicLiteral) -> BoolExpr {
            literal.inverted ? .not(.variable(variables[literal.index])) : .variable(variables[literal.index])
        }
        func gate(_ kind: GateKind, _ items: [BoolExpr]) -> BoolExpr {
            switch kind {
            case .and: .and(items)
            case .or: .or(items)
            case .xor: .xor(items)
            case .nand: .not(.and(items))
            case .nor: .not(.or(items))
            case .xnor: .not(.xor(items))
            default: items.first ?? .constant(false)
            }
        }
        switch plan {
        case nil: return nil
        case .wire(let item): return literal(item)
        case .gate(let kind, let inputs): return gate(kind, inputs.map(literal))
        case .twoLevel(let first, let second, let terms):
            return gate(second, terms.map { $0.count == 1 ? literal($0[0]) : gate(first, $0.map(literal)) })
        }
    }
}

/// An input of a gate in a drawn circuit: a variable, maybe with a circle.
nonisolated struct LogicLiteral: Hashable {
    var index: Int
    var inverted: Bool
}

/// The shape of a drawn circuit (see `LogicAnalysis.plan`).
nonisolated enum LogicPlan: Hashable {
    /// The output is an input (a NOT gate if inverted).
    case wire(LogicLiteral)
    /// One gate.
    case gate(GateKind, [LogicLiteral])
    /// A gate per term and one combining them; a term of one variable goes
    /// straight into the combining gate.
    case twoLevel(first: GateKind, second: GateKind, terms: [[LogicLiteral]])
}

// MARK: - Drawing the circuit

/// Lays out the gates for an analysis on the sheet: the inputs at the top,
/// each with a line running down, the gates to the right of the lines with
/// small circles where an input is inverted, and (for two levels) the gate
/// combining them, wired without crossing, into the output.
nonisolated enum LogicSynthesis {
    static func layout(_ analysis: LogicAnalysis, at origin: GridPoint, outputName: String) -> (gates: [LogicGate], wires: [Wire])? {
        guard let plan = analysis.plan else { return nil }
        if case .twoLevel(_, _, let terms) = plan, terms.count > GateKind.inputRange.upperBound { return nil }
        if case .gate(_, let inputs) = plan, inputs.count > GateKind.inputRange.upperBound { return nil }

        let literals: [LogicLiteral] = switch plan {
        case .wire(let literal): [literal]
        case .gate(_, let inputs): inputs
        case .twoLevel(_, _, let terms): terms.flatMap { $0 }
        }
        let used = Array(Set(literals.map(\.index))).sorted()
        let column = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($0.element, 2 * $0.offset) })
        let gateX = 2 * used.count + 2

        var gates: [LogicGate] = []
        var wires: [Wire] = []
        var taps: [Int: [Int]] = [:]
        func point(_ x: Int, _ y: Int) -> GridPoint { GridPoint(x: origin.x + x, y: origin.y + y) }
        func wire(_ points: [(Int, Int)]) {
            wires.append(Wire(points: Circuit.normalized(points.map { point($0.0, $0.1) })))
        }
        func lineX(_ literal: LogicLiteral) -> Int { column[literal.index] ?? 0 }
        /// A gate whose inputs come straight from the lines, top to bottom in
        /// variable order, with circles on the inverted ones.
        func gate(_ kind: GateKind, _ inputs: [LogicLiteral], center: Int) -> LogicGate {
            let ordered = inputs.sorted { $0.index < $1.index }
            let offsets = LogicGate.inputOffsets(ordered.count)
            var gate = LogicGate(kind: kind, position: point(gateX, center), inputCount: ordered.count)
            for (literal, offset) in zip(ordered, offsets) {
                taps[literal.index, default: []].append(center + offset)
                wire([(lineX(literal), center + offset), (gateX, center + offset)])
                if literal.inverted { gate.toggleInversion(.input(offset)) }
            }
            return gate
        }
        func addInputs() {
            for variable in used {
                let x = column[variable] ?? 0
                gates.append(LogicGate(kind: .input, position: point(x, 0), rotation: 1, name: analysis.variables[variable]))
                wire([(x, 0), (x, taps[variable]?.max() ?? 3)])
            }
        }

        switch plan {
        case .wire(let literal):
            taps[literal.index] = [3]
            if literal.inverted {
                wire([(lineX(literal), 3), (gateX, 3)])
                gates.append(LogicGate(kind: .not, position: point(gateX, 3)))
                wire([(gateX + LogicGate.length, 3), (gateX + LogicGate.length + 3, 3)])
                gates.append(LogicGate(kind: .output, position: point(gateX + LogicGate.length + 3, 3), name: outputName))
            } else {
                wire([(lineX(literal), 3), (gateX + 2, 3)])
                gates.append(LogicGate(kind: .output, position: point(gateX + 2, 3), name: outputName))
            }
            addInputs()
            return (gates, wires)

        case .gate(let kind, let inputs):
            let center = 3 + (LogicGate.inputOffsets(inputs.count).map(abs).max() ?? 0)
            gates.append(gate(kind, inputs, center: center))
            let outputX = gateX + LogicGate.length + 3
            wire([(gateX + LogicGate.length, center), (outputX, center)])
            gates.append(LogicGate(kind: .output, position: point(outputX, center), name: outputName))
            addInputs()
            return (gates, wires)

        case .twoLevel(let first, let second, let terms):
            // The rows of each term: one per input, the gates kept apart.
            var centers: [Int] = []
            var previous: (center: Int, half: Int)?
            for term in terms {
                let reach = term.count >= 2 ? (LogicGate.inputOffsets(term.count).map(abs).max() ?? 0) : 0
                let half = reach + 1
                let center = previous.map { $0.center + $0.half + half + 1 } ?? 3 + reach
                centers.append(center)
                previous = (center, half)
            }
            /// Where each term's signal leaves for the last gate.
            var outputs: [(x: Int, y: Int)] = []
            for (index, term) in terms.enumerated() {
                if term.count == 1 {
                    taps[term[0].index, default: []].append(centers[index])
                    outputs.append((lineX(term[0]), centers[index]))
                } else {
                    gates.append(gate(first, term, center: centers[index]))
                    outputs.append((gateX + LogicGate.length, centers[index]))
                }
            }
            addInputs()

            // The last gate, in the middle, with its inputs in the order of the
            // terms. Wires going down turn in channels nearer the gate the higher
            // up they start, and wires going up the lower down, so none cross.
            let middle = Int((Double(centers[0] + centers[centers.count - 1]) / 2).rounded())
            let offsets = LogicGate.inputOffsets(terms.count)
            let inputRows = offsets.map { middle + $0 }
            let firstOut = gateX + LogicGate.length
            let down = terms.indices.filter { inputRows[$0] > centers[$0] }
            let up = terms.indices.filter { inputRows[$0] < centers[$0] }
            let channels = max(1, down.count, up.count)
            let secondX = firstOut + channels + 2
            var channel: [Int: Int] = [:]
            for (rank, index) in down.enumerated() { channel[index] = firstOut + 1 + (down.count - 1 - rank) }
            for (rank, index) in up.reversed().enumerated() { channel[index] = firstOut + 1 + (up.count - 1 - rank) }
            var last = LogicGate(kind: second, position: point(secondX, middle), inputCount: terms.count)
            for index in terms.indices {
                let start = outputs[index]
                let row = inputRows[index]
                if let x = channel[index] {
                    wire([(start.x, start.y), (x, start.y), (x, row), (secondX, row)])
                } else {
                    wire([(start.x, start.y), (secondX, row)])
                }
                // A term of one inverted variable gets its circle here.
                if terms[index].count == 1, terms[index][0].inverted { last.toggleInversion(.input(offsets[index])) }
            }
            gates.append(last)
            let outputX = secondX + LogicGate.length + 3
            wire([(secondX + LogicGate.length, middle), (outputX, middle)])
            gates.append(LogicGate(kind: .output, position: point(outputX, middle), name: outputName))
            return (gates, wires)
        }
    }
}

// MARK: - Truth table calculator

/// The truth table typed into the calculator: the inputs, the output's
/// value in each row, and how the result is written.
nonisolated struct TruthTableSpec: Hashable {
    static let variableRange = 1...6
    private static let letters = ["A", "B", "C", "D", "E", "F"]

    private(set) var variables = ["A", "B", "C"]
    var outputName = "Y"
    private(set) var values = Array(repeating: TruthValue.zero, count: 8)
    var form = LogicForm.sumOfProducts

    init() {}

    /// A column of a drawn circuit's truth table, to work on further.
    init?(table: LogicTruthTable, output index: Int) {
        guard Self.variableRange.contains(table.variables.count), table.outputs.indices.contains(index) else { return nil }
        let column = table.outputs[index]
        variables = table.variables
        outputName = column.name
        values = column.values.map { $0.map { $0 ? .one : .zero } ?? .dontCare }
    }

    var rowCount: Int { 1 << variables.count }

    /// Sets the number of inputs, named A, B, … The table starts over with zeros.
    mutating func setVariableCount(_ count: Int) {
        let count = min(Self.variableRange.upperBound, max(Self.variableRange.lowerBound, count))
        guard count != variables.count else { return }
        variables = Array(Self.letters.prefix(count))
        values = Array(repeating: .zero, count: 1 << count)
    }

    mutating func setValue(_ value: TruthValue, row: Int) {
        guard values.indices.contains(row) else { return }
        values[row] = value
    }

    /// A click on an output cell: 0 → 1 → X → 0.
    mutating func cycle(row: Int) {
        guard values.indices.contains(row) else { return }
        values[row] = values[row].next
    }

    /// Moves an input to another place in the table. The rows follow, so
    /// every combination keeps its value; only their numbers change.
    mutating func moveVariable(from source: Int, to destination: Int) {
        guard variables.indices.contains(source), variables.indices.contains(destination), source != destination else { return }
        var moved = variables
        moved.insert(moved.remove(at: source), at: destination)
        let count = variables.count
        var newValues = values
        for newRow in 0..<rowCount {
            var oldRow = 0
            for (newIndex, name) in moved.enumerated() where newRow >> (count - 1 - newIndex) & 1 == 1 {
                if let oldIndex = variables.firstIndex(of: name) { oldRow |= 1 << (count - 1 - oldIndex) }
            }
            newValues[newRow] = values[oldRow]
        }
        variables = moved
        values = newValues
    }

    /// Fills the whole output column.
    mutating func fill(_ value: TruthValue) {
        values = Array(repeating: value, count: rowCount)
    }

    func bit(row: Int, variable index: Int) -> Bool {
        row >> (variables.count - 1 - index) & 1 == 1
    }

    var analysis: LogicAnalysis {
        LogicAnalysis(variables: variables, output: outputName.isEmpty ? "Y" : outputName, values: values, form: form)
    }
}
