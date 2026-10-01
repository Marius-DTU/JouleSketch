import SwiftUI

/// A text box on the sheet. Each line is plain text or a LaTeX formula; while
/// typing, ⌘T and ⌘M switch the current line between the two, and ⌘B
/// computes a formula and writes "= result" after it (the keys can be
/// changed in the settings).
struct TextBoxView: View {
    let editor: CircuitEditor
    let box: TextBox
    let isEditing: Bool
    let isSelected: Bool
    let textColor: Color
    let background: Color

    @AppStorage(SettingsKey.studyMode) private var studyMode = false
    @AppStorage(SettingsKey.keyBindings) private var keyBindingsStorage = ""
    @FocusState private var focusedLine: UUID?
    /// Why the last calculation failed, shown under its line.
    @State private var failure: (line: UUID, message: String)?
    /// Something worth knowing about the last calculation, e.g. a unit that
    /// doesn't match the component it's given to.
    @State private var notice: (line: UUID, message: String)?
    /// Set by ⌘⇧U to have the line's field insert unit brackets at its cursor.
    @State private var unitRequest: UnitBracketRequest?

    private static let fontSize: CGFloat = 15

    /// The box as it is in the editor right now. The ⌘ shortcuts can keep an
    /// old copy of the view, so actions read the lines from here, not `box`.
    private var currentBox: TextBox {
        editor.textBox(id: box.id) ?? box
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(box.lines) { line in
                if isEditing {
                    editableLine(line)
                } else {
                    displayedLine(line)
                }
            }
        }
        .padding(6)
        .background {
            if isEditing {
                RoundedRectangle(cornerRadius: 6).fill(background.opacity(0.95))
            }
        }
        .overlay {
            if isEditing || isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: isEditing ? [] : [4, 3]))
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { editor.textBoxSizes[box.id] = $0 }
        .background {
            if isEditing { shortcutButtons }
        }
        .onKeyPress(.escape) {
            editor.endTextEditing()
            return .handled
        }
        .onChange(of: isEditing, initial: true) {
            if isEditing { focusedLine = box.lines.last?.id }
        }
    }

    // MARK: Lines

    @ViewBuilder
    private func displayedLine(_ line: TextLine) -> some View {
        if line.isMath {
            MathRowView(row: LatexParser.parse(line.text), size: Self.fontSize + 1)
                .foregroundStyle(textColor)
        } else {
            Text(line.text)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(textColor)
        }
    }

    private func editableLine(_ line: TextLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    setMath(!line.isMath, on: line.id)
                } label: {
                    Text(line.isMath ? "∑" : "T")
                        .font(.system(size: 11, weight: .semibold, design: line.isMath ? .serif : .default))
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help(line.isMath ? "Math (LaTeX) – skift til tekst" : "Tekst – skift til math (LaTeX)")

                LineField(
                    prompt: line.isMath ? "LaTeX, fx R__eq := R1+R2" : "Tekst",
                    text: text(of: line.id),
                    isMath: line.isMath,
                    lineID: line.id,
                    unitRequest: unitRequest
                )
                    .font(line.isMath ? .system(size: Self.fontSize - 1, design: .monospaced) : .system(size: Self.fontSize))
                    .autocorrectionDisabled()
                    .focused($focusedLine, equals: line.id)
                    .frame(width: max(180, CGFloat(line.text.count) * 9 + 24))
                    .onSubmit { insertLine(after: line) }
                    .onKeyPress(.delete) {
                        guard line.text.isEmpty, box.lines.count > 1 else { return .ignored }
                        removeLine(line)
                        return .handled
                    }
            }
            if line.isMath, !line.text.isEmpty {
                // The formula as it will look, under what's typed.
                MathRowView(row: LatexParser.parse(line.text), size: Self.fontSize + 1)
                    .foregroundStyle(textColor)
                    .padding(.leading, 24)
                if let values = valuesUsed(by: line) {
                    Text(values)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
            if let notice, notice.line == line.id {
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 24)
            }
            if let failure, failure.line == line.id {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 24)
            }
        }
    }

    /// The values the formula takes from the schematic or from definitions
    /// above it, e.g. "R2 = 4,7 kΩ · Req = 5,7 k".
    private func valuesUsed(by line: TextLine) -> String? {
        let variables = variables(before: line.id)
        let row = LatexParser.parse(FormulaParts(line.text).expression)
        let used = MathEvaluator.usedVariables(in: row, variables: variables)
        guard !used.isEmpty else { return nil }
        return used.compactMap { name in
            guard let quantity = variables[name] else { return nil }
            return "\(name) = \(SIValue.format(quantity.value, unit: quantity.unit?.symbol ?? ""))"
        }
        .joined(separator: " · ")
    }

    /// The schematic's values, the document's "!name := …" definitions, and
    /// what the math lines above `lineID` define with "name := expression"
    /// (those only count in this text box).
    private func variables(before lineID: UUID) -> [String: Quantity] {
        var variables = editor.formulaVariables(includeSolved: !studyMode)
            .merging(editor.documentDefinitions) { _, global in global }
        for line in currentBox.lines {
            if line.id == lineID { break }
            let parts = FormulaParts(line.text)
            guard line.isMath, !parts.isGlobal, let key = parts.nameKey, !parts.expression.isEmpty,
                  case .success(let value) = MathEvaluator.evaluate(LatexParser.parse(parts.expression), variables: variables)
            else { continue }
            variables[key] = value
        }
        return variables
    }

    private func text(of id: UUID) -> Binding<String> {
        Binding(
            get: { box.lines.first { $0.id == id }?.text ?? "" },
            set: { newText in
                editor.updateTextBox(id: box.id) { box in
                    guard let index = box.lines.firstIndex(where: { $0.id == id }) else { return }
                    box.lines[index].text = newText
                }
                if failure?.line == id { failure = nil }
            }
        )
    }

    /// Return: a new line in the same mode below the current one.
    private func insertLine(after line: TextLine) {
        let newLine = TextLine(isMath: line.isMath)
        editor.updateTextBox(id: box.id) { box in
            let index = box.lines.firstIndex { $0.id == line.id }.map { $0 + 1 } ?? box.lines.count
            box.lines.insert(newLine, at: index)
        }
        focusedLine = newLine.id
    }

    /// Backspace on an empty line removes it and goes back to the line above.
    private func removeLine(_ line: TextLine) {
        let lines = currentBox.lines
        guard let index = lines.firstIndex(where: { $0.id == line.id }) else { return }
        let previous = lines[max(0, index - 1)].id
        editor.updateTextBox(id: box.id) { $0.lines.removeAll { $0.id == line.id } }
        focusedLine = previous
    }

    // MARK: Modes and calculation

    /// The line being typed in, or the last line.
    private var currentLineID: UUID? {
        focusedLine ?? currentBox.lines.last?.id
    }

    private func setMath(_ isMath: Bool, on id: UUID?) {
        guard let id else { return }
        editor.updateTextBox(id: box.id) { box in
            guard let index = box.lines.firstIndex(where: { $0.id == id }) else { return }
            box.lines[index].isMath = isMath
        }
        focusedLine = id
    }

    /// Computes the formula before any "=" and writes " = result" after it.
    /// A text line is switched to math first.
    private func evaluate() {
        guard let id = currentLineID, let line = currentBox.lines.first(where: { $0.id == id }) else { return }
        let parts = FormulaParts(line.text)
        let expression = parts.expression
        guard !expression.isEmpty else { return }
        let variables = variables(before: id)
        switch MathEvaluator.evaluate(LatexParser.parse(expression), variables: variables) {
        case .success(let value):
            editor.updateTextBox(id: box.id) { box in
                guard let index = box.lines.firstIndex(where: { $0.id == id }) else { return }
                box.lines[index].isMath = true
                // A definition keeps its name: "R__eq := R1+R2 = 5700".
                let definition = parts.name.map { "\($0) := " } ?? ""
                box.lines[index].text = "\(definition)\(expression) = \(MathEvaluator.latex(for: value))"
            }
            failure = nil
            notice = parts.isGlobal ? globalNotice(for: parts, value: value).map { (id, $0) } : nil
        case .failure(.unknown(let name)):
            if editor.formulaUnit(of: name) == nil {
                failure = (id, "Ukendt størrelse: \(name) – den findes hverken i skemaet eller er defineret med := over denne linje")
            } else if studyMode {
                failure = (id, "\(name) har ingen kendt værdi – Study mode skjuler de beregnede værdier")
            } else {
                failure = (id, "\(name) har ingen værdi endnu – angiv den, eller se Beregning for hvad der mangler")
            }
        case .failure(.unknownUnit(let unit)):
            failure = (id, "Ukendt enhed: [[\(unit)]] – brug fx [[V]], [[mA]], [[kΩ]], [[µS]] eller [[W]]")
        case .failure(.math):
            failure = (id, "Kan ikke udregnes (fx division med 0)")
        case .failure(.syntax):
            failure = (id, "Kan ikke læse udtrykket")
        }
        focusedLine = id
    }

    /// What a global definition gives its value to, and a warning if its unit
    /// doesn't match, e.g. "Gælder hele dokumentet og VA – bemærk: …".
    private func globalNotice(for parts: FormulaParts, value: Quantity) -> String? {
        guard let key = parts.nameKey else { return nil }
        guard let unitSymbol = editor.formulaUnit(of: key) else {
            return "\(key) gælder i hele dokumentet"
        }
        if editor.hasTypedInValue(key) {
            return "\(key) har allerede en værdi i skemaet, så tekstfeltet overskriver den ikke"
        }
        if let unit = value.unit, unit != .none, let expected = PhysicalUnit(symbol: unitSymbol), expected != unit {
            return "\(key) er sat i skemaet – bemærk: \(key) måles i \(unitSymbol), men udtrykket giver \(unit.symbol)"
        }
        return "\(key) er sat i skemaet og gælder i hele dokumentet"
    }

    /// Invisible buttons carrying the ⌘ shortcuts while the box is being typed in.
    private var shortcutButtons: some View {
        let bindings = KeyBindings(storageString: keyBindingsStorage)
        return ZStack {
            shortcutButton("Tekst", key: bindings[.textMode]) { setMath(false, on: currentLineID) }
            shortcutButton("Math", key: bindings[.mathMode]) { setMath(true, on: currentLineID) }
            shortcutButton("Udregn", key: bindings[.evaluateMath]) { evaluate() }
            shortcutButton("Enhed", key: bindings[.unitBrackets], modifiers: [.command, .shift]) { insertUnitBrackets() }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func shortcutButton(
        _ title: String, key: String, modifiers: EventModifiers = .command, action: @escaping () -> Void
    ) -> some View {
        if let character = key.first {
            Button(title, action: action)
                .keyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
        }
    }

    /// ⌘⇧U: unit brackets [[ ]] at the cursor of the current line, which
    /// becomes a math line.
    private func insertUnitBrackets() {
        guard let id = currentLineID else { return }
        if currentBox.lines.first(where: { $0.id == id })?.isMath == false { setMath(true, on: id) }
        unitRequest = UnitBracketRequest(line: id, serial: (unitRequest?.serial ?? 0) + 1)
        focusedLine = id
    }
}

#Preview {
    let editor = CircuitEditor()
    let box = TextBox(position: GridPoint(x: 0, y: 0), lines: [
        TextLine(text: "Strøm gennem R1:"),
        TextLine(text: "\\frac{12}{4{,}7 \\cdot 10^{3}} = 2{,}55319 \\cdot 10^{-3}", isMath: true),
    ])
    return VStack(spacing: 20) {
        TextBoxView(editor: editor, box: box, isEditing: false, isSelected: true, textColor: .primary, background: .white)
        TextBoxView(editor: editor, box: box, isEditing: true, isSelected: false, textColor: .primary, background: .white)
    }
    .padding()
}

/// A request for a line's field to insert unit brackets; `serial` changes
/// with every request so the same line can ask again.
private struct UnitBracketRequest: Equatable {
    let line: UUID
    let serial: Int
}

/// The text field of one line. In math lines, typing "__" starts a subscript:
/// it becomes "_{}" with the cursor inside the braces, so what's typed stays
/// subscripted until → moves the cursor past "}". Unit brackets [[ ]] from
/// ⌘⇧U work the same way, and → jumps past "]]".
private struct LineField: View {
    let prompt: String
    @Binding var text: String
    let isMath: Bool
    let lineID: UUID
    let unitRequest: UnitBracketRequest?

    var body: some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            SubscriptingField(prompt: prompt, text: $text, isMath: isMath, lineID: lineID, unitRequest: unitRequest)
        } else {
            // Without cursor control "__" stays in the text (the formula still
            // reads it as a subscript), and unit brackets go at the end.
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .onChange(of: unitRequest) {
                    if unitRequest?.line == lineID { text += "[[]]" }
                }
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
private struct SubscriptingField: View {
    let prompt: String
    @Binding var text: String
    let isMath: Bool
    let lineID: UUID
    let unitRequest: UnitBracketRequest?

    @State private var selection: TextSelection?

    var body: some View {
        TextField(prompt, text: Binding(get: { text }, set: update), selection: $selection)
            .textFieldStyle(.plain)
            .onChange(of: unitRequest) {
                if unitRequest?.line == lineID { insertUnitBrackets() }
            }
            .onKeyPress(.rightArrow) {
                // One press leaves unit brackets: jump past "]]".
                guard let cursor, text[cursor...].hasPrefix("]]") else { return .ignored }
                placeCursor(at: text.distance(from: text.startIndex, to: cursor) + 2)
                return .handled
            }
    }

    /// Where the cursor is, if nothing is selected.
    private var cursor: String.Index? {
        guard case .selection(let range)? = selection?.indices, range.isEmpty,
              range.lowerBound <= text.endIndex else { return nil }
        return range.lowerBound
    }

    /// Puts [[ ]] at the cursor, around any selected text, with the cursor
    /// just before "]]".
    private func insertUnitBrackets() {
        var range = text.endIndex..<text.endIndex
        if case .selection(let selected)? = selection?.indices, selected.upperBound <= text.endIndex {
            range = selected
        }
        let selectedText = String(text[range])
        let offset = text.distance(from: text.startIndex, to: range.lowerBound) + 2 + selectedText.count
        text.replaceSubrange(range, with: "[[\(selectedText)]]")
        placeCursor(at: offset)
    }

    /// Moves the cursor to a character offset, now and once the field has
    /// finished its own update.
    private func placeCursor(at offset: Int) {
        let expected = text
        guard offset <= text.count else { return }
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: offset))
        DispatchQueue.main.async {
            if text == expected, offset <= text.count {
                selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: offset))
            }
        }
    }

    private func update(_ newText: String) {
        guard isMath, let range = newText.range(of: "__") else {
            text = newText
            return
        }
        var converted = newText
        converted.replaceSubrange(range, with: "_{}")
        text = converted
        // Inside the braces: two characters after where "__" began.
        // Inside the braces: two characters after where "__" began.
        placeCursor(at: converted.distance(from: converted.startIndex, to: range.lowerBound) + 2)
    }
}
