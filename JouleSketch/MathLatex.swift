import Foundation

// MARK: - Parsed LaTeX

/// One piece of a LaTeX formula, kept close to how it's written so the same
/// structure can be drawn and computed.
nonisolated indirect enum MathAtom: Hashable {
    /// A number as typed, with "." or "," as the decimal separator.
    case number(String)
    /// A letter or Greek letter, drawn in italics.
    case symbol(String)
    /// An operator or relation such as +, −, ·, / or =.
    case op(String)
    /// A named function such as sin or ln.
    case function(String)
    case fraction(MathRow, MathRow)
    case root(MathRow, index: MathRow?)
    /// Brackets around a row; `{ }` groups have empty delimiters.
    case fenced(open: String, MathRow, close: String)
    case scripts(base: MathAtom, sub: MathRow?, sup: MathRow?)
    /// Upright text from `\text{…}`.
    case text(String)
    /// A unit written as [[kΩ]], like Maple's unit brackets.
    case unit(String)
}

typealias MathRow = [MathAtom]

/// Turns a LaTeX string into a `MathRow`. Unknown commands are shown as text.
nonisolated struct LatexParser {
    private let characters: [Character]
    private var index = 0

    static let functions: Set<String> = [
        "sin", "cos", "tan", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
        "ln", "log", "exp", "abs",
    ]
    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "varphi": "φ", "chi": "χ",
        "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]
    private static let operators: [String: String] = [
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "approx": "≈", "neq": "≠",
        "leq": "≤", "geq": "≥", "to": "→", "infty": "∞", "Rightarrow": "⇒", "checkmark": "✓",
        "angle": "∠", "circ": "°", "ldots": "…",
    ]

    static func parse(_ latex: String) -> MathRow {
        var parser = LatexParser(characters: Array(latex))
        return stackingFractions(parser.parseRow(until: nil))
    }

    /// Turns "a/b" into a stacked fraction, like a math editor: the operands
    /// are what stands between the nearest operators, and brackets around a
    /// whole operand are dropped, so 1/(1/2+1/3) becomes a fraction with
    /// two fractions in its denominator.
    static func stackingFractions(_ row: MathRow) -> MathRow {
        /// Operators that end an operand; postfix ! and % belong to it.
        func separates(_ atom: MathAtom) -> Bool {
            if case .op(let op) = atom { return op != "!" && op != "%" }
            return false
        }
        func unwrapped(_ operand: MathRow) -> MathRow {
            if operand.count == 1, case .fenced(let open, let inner, _) = operand[0], open == "(" || open.isEmpty {
                return inner
            }
            return operand
        }

        let row = row.map(stackingFractions(in:))
        var result: MathRow = []
        var index = 0
        while index < row.count {
            guard case .op("/") = row[index] else {
                result.append(row[index])
                index += 1
                continue
            }
            var numeratorStart = result.count
            while numeratorStart > 0, !separates(result[numeratorStart - 1]) { numeratorStart -= 1 }
            var denominatorEnd = index + 1
            while denominatorEnd < row.count, !separates(row[denominatorEnd]) { denominatorEnd += 1 }
            let numerator = Array(result[numeratorStart...])
            let denominator = Array(row[(index + 1)..<denominatorEnd])
            guard !numerator.isEmpty, !denominator.isEmpty else {
                // Nothing on one side: keep the slash as it is.
                result.append(row[index])
                index += 1
                continue
            }
            result.removeSubrange(numeratorStart...)
            result.append(.fraction(unwrapped(numerator), unwrapped(denominator)))
            index = denominatorEnd
        }
        return result
    }

    /// Stacks fractions inside the rows an atom contains.
    private static func stackingFractions(in atom: MathAtom) -> MathAtom {
        switch atom {
        case .fraction(let numerator, let denominator):
            .fraction(stackingFractions(numerator), stackingFractions(denominator))
        case .root(let radicand, let index):
            .root(stackingFractions(radicand), index: index.map(stackingFractions))
        case .fenced(let open, let inner, let close):
            .fenced(open: open, stackingFractions(inner), close: close)
        case .scripts(let base, let sub, let sup):
            .scripts(base: stackingFractions(in: base), sub: sub.map(stackingFractions), sup: sup.map(stackingFractions))
        case .number, .symbol, .op, .function, .text, .unit:
            atom
        }
    }

    private init(characters: [Character]) {
        self.characters = characters
    }

    private var current: Character? { index < characters.count ? characters[index] : nil }

    /// Parses atoms until `terminator` (consumed) or the end.
    private mutating func parseRow(until terminator: Character?) -> MathRow {
        var row: MathRow = []
        while let c = current {
            if c == terminator {
                index += 1
                return row
            }
            if c == "_", index + 1 < characters.count, characters[index + 1] == "_" {
                // "__" subscripts the letters and digits that follow: R__eq → R_eq.
                index += 2
                var script: MathRow = []
                while let next = current, next.isLetter || next.isNumber {
                    script.append(next.isNumber ? .number(String(next)) : .symbol(String(next)))
                    index += 1
                }
                let base = row.popLast() ?? .text("")
                row.append(Self.attach(script, to: base, isSuper: false))
                continue
            }
            if c == "^" || c == "_" {
                index += 1
                let script = parseArgument()
                let base = row.popLast() ?? .text("")
                row.append(Self.attach(script, to: base, isSuper: c == "^"))
                continue
            }
            if let atom = parseAtom(stoppingAt: terminator) {
                row.append(atom)
            }
        }
        return row
    }

    /// Adds a sub- or superscript to an atom, keeping any script it already has.
    private static func attach(_ script: MathRow, to base: MathAtom, isSuper: Bool) -> MathAtom {
        if case .scripts(let inner, let sub, let sup) = base {
            return .scripts(base: inner, sub: isSuper ? sub : script, sup: isSuper ? script : sup)
        }
        return .scripts(base: base, sub: isSuper ? nil : script, sup: isSuper ? script : nil)
    }

    /// A `{…}` group or a single character/command, as used after ^, _ and \frac.
    private mutating func parseArgument() -> MathRow {
        skipSpaces()
        guard let c = current else { return [] }
        if c == "{" {
            index += 1
            return parseRow(until: "}")
        }
        if c.isNumber {
            // Only one digit, like LaTeX: x^23 is x² followed by 3.
            index += 1
            return [.number(String(c))]
        }
        return parseAtom(stoppingAt: nil).map { [$0] } ?? []
    }

    private mutating func skipSpaces() {
        while let c = current, c.isWhitespace { index += 1 }
    }

    private mutating func parseAtom(stoppingAt terminator: Character?) -> MathAtom? {
        guard let c = current else { return nil }
        if c.isWhitespace {
            index += 1
            return nil
        }
        if c.isNumber || (c == "." || c == ",") && nextIsDigit {
            return parseNumber()
        }
        if c.isLetter {
            index += 1
            return .symbol(String(c))
        }
        switch c {
        case "\\":
            return parseCommand()
        case "{":
            index += 1
            return .fenced(open: "", parseRow(until: "}"), close: "")
        case "(":
            index += 1
            return .fenced(open: "(", parseRow(until: ")"), close: ")")
        case "[" where index + 1 < characters.count && characters[index + 1] == "[":
            return parseUnit()
        case "[":
            index += 1
            return .fenced(open: "[", parseRow(until: "]"), close: "]")
        case "|":
            index += 1
            return .fenced(open: "|", parseRow(until: "|"), close: "|")
        case ":" where index + 1 < characters.count && characters[index + 1] == "=":
            index += 2
            return .op(":=")
        case "*":
            index += 1
            return .op("·")
        case "-":
            index += 1
            return .op("−")
        case "+", "/", "=", "<", ">", "!", "%":
            index += 1
            return .op(String(c))
        default:
            index += 1
            // Stray closing brackets are dropped.
            if c == "}" || c == ")" || c == "]" { return nil }
            return .text(String(c))
        }
    }

    /// A unit in Maple-style brackets: [[kΩ]]. \Omega and "ohm" are read as Ω.
    private mutating func parseUnit() -> MathAtom {
        index += 2
        var text = ""
        while index < characters.count {
            if characters[index] == "]", index + 1 < characters.count, characters[index + 1] == "]" {
                index += 2
                break
            }
            text.append(characters[index])
            index += 1
        }
        var unit = text.trimmingCharacters(in: .whitespaces)
        for spelling in ["\\Omega", "Ohm", "ohm"] {
            unit = unit.replacingOccurrences(of: spelling, with: "Ω")
        }
        unit = unit.replacingOccurrences(of: "\\mu", with: "µ")
        return .unit(unit)
    }

    private var nextIsDigit: Bool {
        index + 1 < characters.count && characters[index + 1].isNumber
    }

    /// Digits with an optional decimal part; "{,}" also counts as a decimal comma.
    private mutating func parseNumber() -> MathAtom {
        var text = ""
        var hasDecimal = false
        while let c = current {
            if c.isNumber {
                text.append(c)
                index += 1
            } else if (c == "." || c == ","), !hasDecimal, nextIsDigit {
                text.append(c)
                hasDecimal = true
                index += 1
            } else if c == "{", !hasDecimal, index + 3 < characters.count,
                      characters[index + 1] == ",", characters[index + 2] == "}", characters[index + 3].isNumber {
                text.append(",")
                hasDecimal = true
                index += 3
            } else {
                break
            }
        }
        return .number(text)
    }

    private mutating func parseCommand() -> MathAtom? {
        index += 1  // Backslash.
        guard let c = current else { return nil }
        guard c.isLetter else {
            // \, \; \! \  are spacing; \{ \} \| are literal brackets.
            index += 1
            switch c {
            case "{": return .fenced(open: "{", parseRow(until: "}"), close: "}")
            case "|": return .text("‖")
            case "%": return .op("%")
            case ",", ";", " ": return .text("\u{2009}")  // Thin space, e.g. before a unit.
            default: return nil
            }
        }
        var name = ""
        while let c = current, c.isLetter {
            name.append(c)
            index += 1
        }
        switch name {
        case "frac", "dfrac", "tfrac":
            let numerator = parseArgument()
            let denominator = parseArgument()
            return .fraction(numerator, denominator)
        case "sqrt":
            var rootIndex: MathRow?
            skipSpaces()
            if current == "[" {
                index += 1
                rootIndex = parseRow(until: "]")
            }
            return .root(parseArgument(), index: rootIndex)
        case "left", "right", "big", "Big", "bigg", "Bigg":
            // The next character is a bracket that the parser handles itself.
            return nil
        case "text", "mathrm", "operatorname":
            let content = parseArgument()
            return .text(Self.plainText(content))
        case "quad", "qquad":
            return nil
        default:
            if Self.functions.contains(name) { return .function(name) }
            if let letter = Self.greek[name] { return .symbol(letter) }
            if let op = Self.operators[name] { return .op(op) }
            return .text(name)
        }
    }

    /// The characters of a row without formatting, e.g. for `\text{…}`.
    static func plainText(_ row: MathRow) -> String {
        row.map { atom in
            switch atom {
            case .number(let s), .symbol(let s), .op(let s), .function(let s), .text(let s), .unit(let s): s
            case .fenced(let open, let inner, let close): open + plainText(inner) + close
            case .scripts(let base, let sub, let sup):
                plainText([base]) + (sub.map { plainText($0) } ?? "") + (sup.map { "^" + plainText($0) } ?? "")
            case .fraction(let a, let b): plainText(a) + "/" + plainText(b)
            case .root(let a, _): "√" + plainText(a)
            }
        }.joined()
    }
}

// MARK: - Computing

/// A math line split into its parts: "name := expression = result", where
/// the name and the result are optional.
nonisolated struct FormulaParts {
    /// The LaTeX of the name a definition gives a value, e.g. "R__eq".
    let name: String?
    /// The LaTeX of what to compute.
    let expression: String

    init(_ text: String) {
        var rest = Substring(text)
        var name: String?
        if let range = text.range(of: ":=") {
            let before = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if !before.isEmpty { name = before }
            rest = text[range.upperBound...]
        }
        self.name = name
        expression = rest.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// A definition starting with "!" applies to the whole document and gives
    /// its value to everything on the schematic with that name.
    var isGlobal: Bool { name?.hasPrefix("!") ?? false }

    /// The name as formulas look it up: R__eq and R_{eq} both become "Req",
    /// and !VA becomes "VA".
    var nameKey: String? {
        name.map { Self.key($0.hasPrefix("!") ? String($0.dropFirst()) : $0) }
    }

    /// A name without "_", "{", "}" and spaces.
    static func key(_ name: String) -> String {
        name.filter { !"_{} ".contains($0) }
    }
}

/// An electrical unit as powers of volt and ampere: Ω = V/A, S = A/V, W = V·A.
nonisolated struct PhysicalUnit: Hashable {
    var volt: Int
    var ampere: Int

    static let none = PhysicalUnit(volt: 0, ampere: 0)
    static let volt = PhysicalUnit(volt: 1, ampere: 0)
    static let ampere = PhysicalUnit(volt: 0, ampere: 1)
    static let ohm = PhysicalUnit(volt: 1, ampere: -1)
    static let siemens = PhysicalUnit(volt: -1, ampere: 1)
    static let watt = PhysicalUnit(volt: 1, ampere: 1)

    /// The unit of a value on the schematic, from its symbol ("Ω", "V/V", …).
    init?(symbol: String) {
        switch symbol {
        case "V": self = .volt
        case "A": self = .ampere
        case "Ω", "V/A": self = .ohm
        case "S", "A/V": self = .siemens
        case "W": self = .watt
        case "V/V", "A/A", "": self = .none
        default: return nil
        }
    }

    init(volt: Int, ampere: Int) {
        self.volt = volt
        self.ampere = ampere
    }

    private static let unitSymbols: [String: PhysicalUnit] = [
        "V": .volt, "A": .ampere, "Ω": .ohm, "S": .siemens, "W": .watt,
    ]
    private static let prefixes: [String: Double] = [
        "p": 1e-12, "n": 1e-9, "µ": 1e-6, "μ": 1e-6, "u": 1e-6, "m": 1e-3, "k": 1e3, "M": 1e6, "G": 1e9,
    ]

    /// A unit written in a formula, e.g. "A", "kΩ" or "mA", as a quantity
    /// (1 mA is 0.001 A), or `nil` if it isn't a unit.
    static func quantity(writtenAs text: String) -> Quantity? {
        if let unit = unitSymbols[text] { return Quantity(1, unit: unit) }
        guard text.count == 2, let factor = prefixes[String(text.prefix(1))],
              let unit = unitSymbols[String(text.suffix(1))] else { return nil }
        return Quantity(factor, unit: unit)
    }

    static func * (lhs: PhysicalUnit, rhs: PhysicalUnit) -> PhysicalUnit {
        PhysicalUnit(volt: lhs.volt + rhs.volt, ampere: lhs.ampere + rhs.ampere)
    }

    static func / (lhs: PhysicalUnit, rhs: PhysicalUnit) -> PhysicalUnit {
        PhysicalUnit(volt: lhs.volt - rhs.volt, ampere: lhs.ampere - rhs.ampere)
    }

    /// The symbol, e.g. "Ω", or powers such as "V²/A" for other combinations.
    var symbol: String {
        switch self {
        case .none: return ""
        case .volt: return "V"
        case .ampere: return "A"
        case .ohm: return "Ω"
        case .siemens: return "S"
        case .watt: return "W"
        default:
            func power(_ symbol: String, _ exponent: Int) -> String {
                let superscripts: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
                let digits = exponent == 1 ? "" : String(String(exponent).compactMap { $0.wholeNumberValue.map { superscripts[$0] } })
                return symbol + digits
            }
            // Ω² and S² rather than V²/A² and A²/V².
            if volt == -ampere { return volt > 0 ? power("Ω", volt) : power("S", ampere) }
            let numerator = [volt > 0 ? power("V", volt) : nil, ampere > 0 ? power("A", ampere) : nil].compactMap { $0 }
            let denominator = [volt < 0 ? power("V", -volt) : nil, ampere < 0 ? power("A", -ampere) : nil].compactMap { $0 }
            let top = numerator.isEmpty ? "1" : numerator.joined(separator: "·")
            return denominator.isEmpty ? top : top + "/" + denominator.joined(separator: "·")
        }
    }
}

/// A value with its unit. The unit is `nil` when it can't be known, e.g.
/// after adding a resistance to a voltage.
nonisolated struct Quantity: Hashable {
    var value: Double
    var unit: PhysicalUnit? = PhysicalUnit.none

    init(_ value: Double, unit: PhysicalUnit? = PhysicalUnit.none) {
        self.value = value
        self.unit = unit
    }

    static func + (lhs: Quantity, rhs: Quantity) -> Quantity {
        Quantity(lhs.value + rhs.value, unit: lhs.unit == rhs.unit ? lhs.unit : nil)
    }

    static func - (lhs: Quantity, rhs: Quantity) -> Quantity {
        Quantity(lhs.value - rhs.value, unit: lhs.unit == rhs.unit ? lhs.unit : nil)
    }

    static func * (lhs: Quantity, rhs: Quantity) -> Quantity {
        Quantity(lhs.value * rhs.value, unit: lhs.unit.flatMap { a in rhs.unit.map { a * $0 } })
    }

    static func / (lhs: Quantity, rhs: Quantity) -> Quantity {
        Quantity(lhs.value / rhs.value, unit: lhs.unit.flatMap { a in rhs.unit.map { a / $0 } })
    }

    static prefix func - (quantity: Quantity) -> Quantity {
        Quantity(-quantity.value, unit: quantity.unit)
    }

    /// Raises to a power; units follow whole exponents, e.g. A² from A^2.
    func raised(to exponent: Quantity) -> Quantity {
        let value = pow(self.value, exponent.value)
        guard exponent.unit == PhysicalUnit.none, let unit else { return Quantity(value, unit: nil) }
        if unit == .none { return Quantity(value) }
        guard exponent.value == exponent.value.rounded(), abs(exponent.value) < 10 else { return Quantity(value, unit: nil) }
        let n = Int(exponent.value)
        return Quantity(value, unit: PhysicalUnit(volt: unit.volt * n, ampere: unit.ampere * n))
    }

    /// The n-th root; the unit survives when its powers divide evenly (√(Ω²) = Ω).
    func root(_ n: Double) -> Quantity {
        let value = self.value < 0 && n.truncatingRemainder(dividingBy: 2) == 1
            ? -pow(-self.value, 1 / n)
            : pow(self.value, 1 / n)
        guard let unit, n == n.rounded(), n >= 1 else { return Quantity(value, unit: nil) }
        let k = Int(n)
        guard unit.volt % k == 0, unit.ampere % k == 0 else { return Quantity(value, unit: nil) }
        return Quantity(value, unit: PhysicalUnit(volt: unit.volt / k, ampere: unit.ampere / k))
    }
}

/// Computes the value of a formula with units. Letters and names such as
/// R_1 or V_A are looked up in `variables`; π and e are known.
nonisolated struct MathEvaluator {
    enum Failure: Error {
        case unknown(String)
        /// A unit in [[ ]] that isn't known.
        case unknownUnit(String)
        case syntax
        case math
    }

    private let variables: [String: Quantity]
    private let recorder: Recorder
    private var atoms: MathRow
    private var index = 0

    /// Collects the names of the variables a calculation uses.
    private final class Recorder {
        var names: [String] = []

        func record(_ name: String) {
            if !names.contains(name) { names.append(name) }
        }
    }

    /// The variables the formula before the first "=" uses, in order.
    static func usedVariables(in row: MathRow, variables: [String: Quantity]) -> [String] {
        let recorder = Recorder()
        let beforeEquals = Array(row.prefix { $0 != .op("=") })
        _ = try? evaluateRow(beforeEquals, variables: variables, recorder: recorder)
        return recorder.names
    }

    /// Evaluates everything before the first "=".
    static func evaluate(_ row: MathRow, variables: [String: Quantity]) -> Result<Quantity, Failure> {
        let beforeEquals = Array(row.prefix { $0 != .op("=") })
        do {
            let quantity = try evaluateRow(beforeEquals, variables: variables, recorder: Recorder())
            guard quantity.value.isFinite else { return .failure(.math) }
            return .success(quantity)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.syntax)
        }
    }

    /// Evaluates plain numbers without units.
    static func evaluate(_ row: MathRow, variables: [String: Double]) -> Result<Double, Failure> {
        evaluate(row, variables: variables.mapValues { Quantity($0) }).map(\.value)
    }

    private static func evaluateRow(_ row: MathRow, variables: [String: Quantity], recorder: Recorder) throws -> Quantity {
        // Spacing such as \, doesn't take part.
        let row = row.filter { atom in
            if case .text(let text) = atom { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
            return true
        }
        var evaluator = MathEvaluator(variables: variables, atoms: row, recorder: recorder)
        guard !row.isEmpty else { throw Failure.syntax }
        let value = try evaluator.parseSum()
        guard evaluator.index == row.count else { throw Failure.syntax }
        return value
    }

    private func evaluate(_ row: MathRow) throws -> Quantity {
        try Self.evaluateRow(row, variables: variables, recorder: recorder)
    }

    private init(variables: [String: Quantity], atoms: MathRow, recorder: Recorder) {
        self.variables = variables
        self.atoms = atoms
        self.recorder = recorder
    }

    private var current: MathAtom? { index < atoms.count ? atoms[index] : nil }

    private mutating func parseSum() throws -> Quantity {
        var value = try parseProduct()
        while case .op(let op)? = current, op == "+" || op == "−" {
            index += 1
            let rhs = try parseProduct()
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseProduct() throws -> Quantity {
        var value = try parseSigned()
        while let atom = current {
            if case .op(let op) = atom, ["·", "×", "/", "÷"].contains(op) {
                index += 1
                let rhs = try parseSigned()
                value = (op == "/" || op == "÷") ? value / rhs : value * rhs
            } else if case .op = atom {
                break
            } else {
                // Implicit multiplication: 2R_1, 2(3+4), 2\pi.
                value = value * (try parsePower())
            }
        }
        return value
    }

    private mutating func parseSigned() throws -> Quantity {
        if case .op(let op)? = current, op == "−" || op == "+" {
            index += 1
            let value = try parseSigned()
            return op == "−" ? -value : value
        }
        return try parsePower()
    }

    /// A value with an optional % after it.
    private mutating func parsePower() throws -> Quantity {
        var value = try parsePrimary()
        if case .op("%")? = current {
            index += 1
            value.value /= 100
        }
        return value
    }

    private mutating func parsePrimary() throws -> Quantity {
        guard let atom = current else { throw Failure.syntax }

        // A name made of several letters and digits, e.g. R1 or VA.
        if let (name, value, length) = try longestVariable(at: index) {
            recorder.record(name)
            index += length
            return value
        }

        index += 1
        switch atom {
        case .number(let text):
            guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { throw Failure.syntax }
            return Quantity(value)
        case .symbol(let name):
            do {
                return try constant(name)
            } catch {
                // Report "R3" rather than "R" when digits follow the letter.
                var fullName = name
                var next = index
                while next < atoms.count, case .number(let digits) = atoms[next] {
                    fullName += digits
                    next += 1
                }
                throw Failure.unknown(fullName)
            }
        case .function(let name):
            let argument = try parsePower()
            return try Self.apply(name, to: argument, base: nil)
        case .fraction(let numerator, let denominator):
            return try evaluate(numerator) / evaluate(denominator)
        case .root(let radicand, let rootIndex):
            let n = try rootIndex.map { try evaluate($0).value } ?? 2
            return try evaluate(radicand).root(n)
        case .fenced(let open, let inner, _):
            var value = try evaluate(inner)
            if open == "|" { value.value = abs(value.value) }
            return value
        case .scripts(let base, let sub, let sup):
            if case .function(let name) = base {
                // \log_2 x, \sin^2 x
                let argument = try parsePower()
                let logBase = try sub.map { try evaluate($0).value }
                let value = try Self.apply(name, to: argument, base: logBase)
                return try sup.map { value.raised(to: try evaluate($0)) } ?? value
            }
            let baseValue: Quantity
            if let sub, case .symbol(let letter) = base {
                let name = letter + Self.name(of: sub)
                guard let value = variables[name] else { throw Failure.unknown(name) }
                recorder.record(name)
                baseValue = value
            } else {
                baseValue = try evaluate([base])
            }
            return try sup.map { baseValue.raised(to: try evaluate($0)) } ?? baseValue
        case .unit(let text):
            guard let unit = PhysicalUnit.quantity(writtenAs: text) else { throw Failure.unknownUnit(text) }
            return unit
        case .op, .text:
            throw Failure.syntax
        }
    }

    private func constant(_ name: String) throws -> Quantity {
        if let value = variables[name] {
            recorder.record(name)
            return value
        }
        switch name {
        case "π": return Quantity(.pi)
        case "e": return Quantity(M_E)
        default: throw Failure.unknown(name)
        }
    }

    /// The longest run of letters and digits starting at `start` that names a
    /// variable of two or more characters: its name, value and how many atoms it
    /// spans. An exponent on the last letter applies to the whole name (IC^2).
    private func longestVariable(at start: Int) throws -> (name: String, value: Quantity, length: Int)? {
        guard case .symbol = atoms[start] else { return nil }
        var name = ""
        var best: (name: String, value: Quantity, length: Int)?
        var end = start
        while end < atoms.count {
            switch atoms[end] {
            case .symbol(let s), .number(let s): name += s
            case .scripts(.symbol(let s), let sub?, nil): name += s + Self.name(of: sub)
            case .scripts(.symbol(let s), let sub, let sup?), .scripts(.number(let s), let sub, let sup?):
                // The name ends here, raised to the exponent.
                let fullName = name + s + (sub.map(Self.name(of:)) ?? "")
                guard fullName.count >= 2, let value = variables[fullName] else { return best }
                return (fullName, value.raised(to: try evaluate(sup)), end + 1 - start)
            default: return best
            }
            end += 1
            if end - start >= 2 || name.count >= 2, let value = variables[name] {
                best = (name, value, end - start)
            }
        }
        return best
    }

    /// A subscript as part of a name: R_{1} → "1".
    private static func name(of row: MathRow) -> String {
        LatexParser.plainText(row).replacingOccurrences(of: " ", with: "")
    }

    /// Functions need a plain number; |x| keeps the unit.
    private static func apply(_ name: String, to argument: Quantity, base: Double?) throws -> Quantity {
        let x = argument.value
        if name == "abs" { return Quantity(abs(x), unit: argument.unit) }
        let unit: PhysicalUnit? = argument.unit == PhysicalUnit.none ? PhysicalUnit.none : nil
        let value: Double = switch name {
        case "sin": sin(x)
        case "cos": cos(x)
        case "tan": tan(x)
        case "arcsin": asin(x)
        case "arccos": acos(x)
        case "arctan": atan(x)
        case "sinh": sinh(x)
        case "cosh": cosh(x)
        case "tanh": tanh(x)
        case "ln": log(x)
        case "log": base.map { log(x) / log($0) } ?? log10(x)
        case "exp": exp(x)
        default: throw Failure.syntax
        }
        return Quantity(value, unit: unit)
    }

    private static func digits(_ x: Double) -> String {
        var text = String(format: "%.6g", x)
        if text.contains("e") { text = String(format: "%.6f", x) }
        return text.replacingOccurrences(of: ".", with: ",")
    }

    /// A result as LaTeX, with a decimal comma and powers of ten for very
    /// large or small numbers.
    static func latex(for value: Double) -> String {
        let magnitude = abs(value)
        if magnitude != 0, magnitude >= 1e6 || magnitude < 1e-2 {
            let exponent = Int(floor(log10(magnitude)))
            let mantissa = value / pow(10, Double(exponent))
            return "\(digits(mantissa)) \\cdot 10^{\(exponent)}"
        }
        return digits(value)
    }

    /// A result with its unit in Maple-style brackets and an SI prefix, e.g. "12 [[kΩ]]".
    static func latex(for quantity: Quantity) -> String {
        guard let unit = quantity.unit, unit != .none else { return latex(for: quantity.value) }
        let prefixes: [Int: String] = [-12: "p", -9: "n", -6: "µ", -3: "m", 0: "", 3: "k", 6: "M", 9: "G", 12: "T"]
        let magnitude = abs(quantity.value)
        var exponent = magnitude == 0 ? 0 : Int(floor(log10(magnitude) / 3)) * 3
        exponent = min(12, max(-12, exponent))
        let mantissa = quantity.value / pow(10, Double(exponent))
        return "\(digits(mantissa)) [[\(prefixes[exponent] ?? "")\(unit.symbol)]]"
    }
}
