import Foundation

/// Turns the Maple code from `MapleExporter` and the walkthroughs into
/// MathML. Pasted as text into a Maple worksheet, Maple reads it as 2-D Math,
/// so names with "__" come in lowered (V__A as V with A below it), divisions
/// as fractions and powers raised, and it still runs.
///
/// Each statement goes on its own line; comment lines are left out, since
/// MathML has no comments. Quotes are dropped (`Unit('V')` becomes
/// `Unit(V)`), which is safe because the output never uses V, A, ohm, … as
/// variables. The code must not use square brackets, which MathML would
/// turn into subscripts.
nonisolated enum MapleMathML {
    static func convert(_ code: String) -> String {
        var rows: [String] = []
        for line in code.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            var parser = Parser(tokens: tokenize(trimmed))
            rows.append(parser.statements())
        }
        return "<math><mrow>" + rows.joined(separator: "<mspace linebreak=\"newline\"/>") + "</mrow></math>"
    }

    // MARK: Tokens

    fileprivate enum Token: Equatable {
        case name(String)
        case number(String)
        case op(String)
    }

    private static func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(line)
        var index = 0
        func isNameCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        while index < characters.count {
            let c = characters[index]
            if c.isWhitespace {
                index += 1
            } else if c == "#" {
                break
            } else if c == "'" || c == "`" {
                // 'ohm', `name` and '`k&Omega;`' are names; the quotes go, and
                // Maple's &Omega; and &mu; become the letters Ω and μ.
                var end = index + 1
                while end < characters.count, characters[end] != c { end += 1 }
                let quoted = String(characters[(index + 1)..<min(end, characters.count)])
                tokens.append(.name(quoted.filter { $0 != "`" }
                    .replacingOccurrences(of: "&Omega;", with: "Ω")
                    .replacingOccurrences(of: "&mu;", with: "μ")))
                index = end + 1
            } else if c.isNumber || (c == "." && index + 1 < characters.count && characters[index + 1].isNumber) {
                var end = index
                while end < characters.count, characters[end].isNumber || characters[end] == "." { end += 1 }
                tokens.append(.number(String(characters[index..<end])))
                index = end
            } else if c.isLetter || c == "_" {
                var end = index
                while end < characters.count, isNameCharacter(characters[end]) { end += 1 }
                tokens.append(.name(String(characters[index..<end])))
                index = end
            } else if c == ":", index + 1 < characters.count, characters[index + 1] == "=" {
                tokens.append(.op(":="))
                index += 2
            } else {
                tokens.append(.op(String(c)))
                index += 1
            }
        }
        return tokens
    }

    // MARK: Markup

    fileprivate static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Greek gain names, shown as their letter.
    private static let greek = ["beta": "β", "mu": "μ", "alpha": "α", "gamma": "γ", "omega": "ω"]

    /// `<mi>` for a name, or `<msub>` for one with a "__" subscript.
    fileprivate static func name(_ name: String) -> String {
        func identifier(_ text: String) -> String {
            if let letter = greek[text] { return "<mi>\(letter)</mi>" }
            return text.allSatisfy(\.isNumber) ? "<mn>\(text)</mn>" : "<mi>\(escape(text))</mi>"
        }
        guard let range = name.range(of: "__"), range.lowerBound != name.startIndex, range.upperBound != name.endIndex else {
            return identifier(name)
        }
        return "<msub>\(identifier(String(name[..<range.lowerBound])))\(identifier(String(name[range.upperBound...])))</msub>"
    }

    fileprivate static func op(_ symbol: String) -> String {
        let shown = switch symbol {
        case "*": "&#x22C5;"
        case "-": "&#x2212;"
        default: escape(symbol)
        }
        return "<mo>\(shown)</mo>"
    }
}

/// Recursive descent over one line of Maple code, giving MathML.
nonisolated private struct Parser {
    typealias Token = MapleMathML.Token

    /// A piece of MathML; `inner` is the same without surrounding brackets,
    /// used where a fraction or power makes them unnecessary.
    struct Node {
        var xml: String
        var inner: String?
        var bare: String { inner ?? xml }
    }

    let tokens: [Token]
    var index = 0

    init(tokens: [Token]) { self.tokens = tokens }

    private var current: Token? { index < tokens.count ? tokens[index] : nil }

    private mutating func take(_ symbol: String) -> Bool {
        guard current == .op(symbol) else { return false }
        index += 1
        return true
    }

    /// Statements with their `:` or `;`.
    mutating func statements() -> String {
        var xml = ""
        while current != nil {
            let start = index
            xml += assignment().xml
            for terminator in [":", ";"] where take(terminator) { xml += MapleMathML.op(terminator) }
            // Anything the grammar doesn't know is passed on as it is.
            if index == start, let token = current {
                index += 1
                xml += Self.plain(token)
            }
        }
        return xml
    }

    private static func plain(_ token: Token) -> String {
        switch token {
        case .name(let name): MapleMathML.name(name)
        case .number(let number): "<mn>\(number)</mn>"
        case .op(let symbol): MapleMathML.op(symbol)
        }
    }

    private mutating func assignment() -> Node {
        var node = relation()
        if take(":=") { node = Node(xml: node.xml + MapleMathML.op(":=") + relation().xml) }
        return node
    }

    private mutating func relation() -> Node {
        var node = sum()
        if take("=") { node = Node(xml: node.xml + MapleMathML.op("=") + sum().xml) }
        return node
    }

    private mutating func sum() -> Node {
        var xml = ""
        var terms = 0
        if take("-") { xml += MapleMathML.op("-") }
        var node = term()
        xml += node.xml
        terms += 1
        while let symbol = [("+"), ("-")].first(where: { current == .op($0) }) {
            index += 1
            node = term()
            xml += MapleMathML.op(symbol) + node.xml
            terms += 1
        }
        return terms == 1 && !xml.hasPrefix("<mo>") ? node : Node(xml: "<mrow>\(xml)</mrow>")
    }

    /// Products and quotients: a*b/c is the fraction (a⋅b)/c.
    private mutating func term() -> Node {
        var node = factor()
        while true {
            if take("*") {
                node = Node(xml: "<mrow>\(node.xml)\(MapleMathML.op("*"))\(factor().xml)</mrow>")
            } else if take("/") {
                let denominator = factor()
                node = Node(xml: "<mfrac><mrow>\(node.bare)</mrow><mrow>\(denominator.bare)</mrow></mfrac>")
            } else {
                return node
            }
        }
    }

    private mutating func factor() -> Node {
        if take("-") { return Node(xml: "<mrow>\(MapleMathML.op("-"))\(factor().xml)</mrow>") }
        let base = primary()
        guard take("^") else { return base }
        let exponent = factor()
        return Node(xml: "<msup>\(base.xml)<mrow>\(exponent.bare)</mrow></msup>")
    }

    private mutating func primary() -> Node {
        switch current {
        case .number(let number)?:
            index += 1
            return Node(xml: "<mn>\(number)</mn>")
        case .name(let name)?:
            index += 1
            let identifier = MapleMathML.name(name)
            guard current == .op("(") else { return Node(xml: identifier) }
            // A function call: Unit(V), solve({L1}, {V__A}).
            let arguments = bracketed("(", ")")
            return Node(xml: "<mrow>\(identifier)<mo>&#x2061;</mo>\(arguments.xml)</mrow>")
        case .op("(")?:
            return bracketed("(", ")")
        case .op("{")?:
            return bracketed("{", "}")
        default:
            return Node(xml: "")
        }
    }

    /// `(a, b)` or `{a, b}`; `inner` leaves out the brackets.
    private mutating func bracketed(_ open: String, _ close: String) -> Node {
        _ = take(open)
        var items: [String] = []
        while current != nil, current != .op(close) {
            let start = index
            items.append(assignment().xml)
            if !take(","), index == start { index += 1 }
        }
        _ = take(close)
        let inner = items.joined(separator: MapleMathML.op(","))
        return Node(xml: "<mrow>\(MapleMathML.op(open))\(inner)\(MapleMathML.op(close))</mrow>", inner: inner)
    }
}
