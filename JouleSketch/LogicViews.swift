import SwiftUI

// MARK: - Drawing shared primitives

/// Draws the shared code's primitives (`SymbolPainter`, `ToolIconScene`) in
/// a SwiftUI canvas, so logic symbols look the same as on the web.
enum ScenePrimitiveRenderer {
    /// With a `tint`, everything is drawn in that color (keeping each
    /// primitive's opacity), as tool icons are.
    static func draw(_ primitives: [ScenePrimitive], in context: GraphicsContext, tint: Color? = nil) {
        func color(_ color: SceneColor) -> Color {
            tint.map { $0.opacity(color.a) } ?? Color(color)
        }
        for primitive in primitives {
            switch primitive {
            case .stroke(let ops, let stroke, let width, let dash, let roundCap):
                context.stroke(
                    path(ops), with: .color(color(stroke)),
                    style: StrokeStyle(lineWidth: width, lineCap: roundCap ? .round : .butt, lineJoin: .round, dash: dash)
                )
            case .fill(let ops, let fill, let evenOdd):
                context.fill(path(ops), with: .color(color(fill)), style: FillStyle(eoFill: evenOdd))
            case .text(let runs, let point, let anchor):
                var text = Text("")
                for run in runs {
                    let piece = Text(run.text)
                        .font(.system(size: run.size, weight: weight(run.weight)))
                        .italic(run.italic)
                        .baselineOffset(run.baseline)
                        .foregroundStyle(color(run.color))
                    text = Text("\(text)\(piece)")
                }
                context.draw(text, at: point, anchor: UnitPoint(x: anchor.x, y: anchor.y))
            case .dots(let points, let size, let dots):
                var path = Path()
                for p in points { path.addRect(CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)) }
                context.fill(path, with: .color(color(dots)))
            }
        }
    }

    static func path(_ ops: [PathOp]) -> Path {
        var path = Path()
        for op in ops {
            switch op {
            case .move(let p): path.move(to: p)
            case .line(let p): path.addLine(to: p)
            case .close: path.closeSubpath()
            case .ellipse(let rect): path.addEllipse(in: rect)
            case .rect(let rect): path.addRect(rect)
            case .roundedRect(let rect, let radius): path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
            }
        }
        return path
    }

    private static func weight(_ value: Int) -> Font.Weight {
        switch value {
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
    }
}

extension Color {
    init(_ color: SceneColor) {
        self.init(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: color.a)
    }
}

// MARK: - Start page

/// Shown in a new, empty document: pick whether the sheet is analog or digital.
struct StartView: View {
    let editor: CircuitEditor

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Text("Hvad vil du tegne?")
                        .font(.largeTitle.bold())
                    Text("Vælg, hvad arket skal bruges til. Valget gemmes i filen.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) { cards }
                    VStack(spacing: 16) { cards }
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.957, green: 0.953, blue: 0.937).opacity(0.5))
    }

    @ViewBuilder
    private var cards: some View {
        card(
            .analog, title: "Analog",
            text: "Modstande, kilder, dioder, kondensatorer og spoler. Programmet beregner spændinger, strømme og effekter og viser udregningen og Maple-koden."
        )
        card(
            .digital, title: "Digital",
            text: "Logiske gates – AND, OR, NOT, NAND, NOR, XOR og XNOR. Sandhedstabeller og Karnaugh-kort for det, du tegner, og en lommeregner, der finder de gates, en sandhedstabel kræver."
        )
    }

    private func card(_ mode: SheetMode, title: String, text: String) -> some View {
        Button {
            editor.chooseMode(mode)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Canvas { context, size in
                    var painter = SymbolPainter(unit: 14)
                    let color = SceneColor(0.62, 0.1, 0.12)
                    let middle = size.height / 2
                    switch mode {
                    case .analog:
                        painter.component(.voltageSource, from: CGPoint(x: 10, y: middle), to: CGPoint(x: 80, y: middle), color: color, lineWidth: 2)
                        painter.component(.resistor, from: CGPoint(x: 100, y: middle), to: CGPoint(x: 170, y: middle), color: color, lineWidth: 2)
                    case .digital:
                        painter.gate(LogicGate(kind: .and, position: GridPoint(x: 0, y: 0)), at: CGPoint(x: 10, y: middle), color: color, lineWidth: 2)
                        painter.gate(LogicGate(kind: .nor, position: GridPoint(x: 0, y: 0)), at: CGPoint(x: 100, y: middle), color: color, lineWidth: 2)
                    }
                    ScenePrimitiveRenderer.draw(painter.primitives, in: context)
                }
                .frame(width: 180, height: 56)
                Text(title)
                    .font(.title2.bold())
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(mode == .analog ? "Opret analogt ark" : "Opret digitalt ark")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }
            .multilineTextAlignment(.leading)
            .padding(24)
            .frame(width: 320, height: 300, alignment: .topLeading)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .analog ? "Analogt ark" : "Digitalt ark")
        .accessibilityHint(text)
    }
}

// MARK: - Gate properties

/// The properties of a gate, input or output, in the inspector and the symbol editor.
struct GateFields: View {
    let editor: CircuitEditor
    let gate: LogicGate
    /// Called when a block is opened from its fields, e.g. to close the editor.
    var onOpenBlock: (() -> Void)?

    @AppStorage(SettingsKey.blockLibrary) private var library = ""

    var body: some View {
        if gate.kind == .block {
            TextField("Navn", text: Binding(
                get: { gate.name },
                set: { name in editor.updateGate(id: gate.id) { $0.name = name } }
            ))
            pinEditor("Indgange", names: gate.blockInputs) { names in editor.updateGate(id: gate.id) { $0.blockInputs = names } }
            pinEditor("Udgange", names: gate.blockOutputs) { names in editor.updateGate(id: gate.id) { $0.blockOutputs = names } }
            Text("Ét navn pr. linje, oppefra. En tom linje giver et mellemrum uden ben. Ledningerne følger med, når benene flyttes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Åbn blokken", systemImage: "square.stack.3d.down.right") {
                editor.enterBlock(id: gate.id)
                onOpenBlock?()
            }
            .help("Byg, hvad blokken gør (eller dobbeltklik på den)")
            Button("Gem i biblioteket", systemImage: "books.vertical") {
                var saved = BlockLibrary(storageString: library)
                saved.add(gate)
                library = saved.storageString
            }
            .help("Gem blokken med indhold, så den kan placeres igen fra Bibliotek")
        } else if gate.kind.isConstant {
            LabeledContent("Værdi", value: gate.kind == .high ? "1" : "0")
            Text(gate.kind == .high
                 ? "Det, der forbindes til 5V, er altid 1. Alle 5V-flag er det samme signal."
                 : "Det, der forbindes til GND, er altid 0. Alle GND-flag er det samme signal.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if gate.kind.isGate {
            Picker("Type", selection: Binding(
                get: { gate.kind },
                set: { kind in editor.updateGate(id: gate.id) { $0.kind = kind } }
            )) {
                ForEach(GateKind.gates) { kind in
                    Text(kind.shortName).tag(kind)
                }
            }
            if gate.kind.allowsMoreInputs {
                Stepper(value: Binding(
                    get: { gate.inputCount },
                    set: { count in editor.updateGate(id: gate.id) { $0.inputCount = count } }
                ), in: GateKind.inputRange) {
                    LabeledContent("Indgange", value: "\(gate.inputCount)")
                }
            }
        } else {
            if editor.isInsideBlock {
                // Named after one of the block's terminals.
                LabeledContent("Navn", value: gate.name)
                Text("Navnet er et af blokkens ben. Ret benene i blokkens egenskaber (højreklik på blokken).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Navn", text: Binding(
                    get: { gate.name },
                    set: { name in editor.updateGate(id: gate.id) { $0.name = name } }
                ))
            }
            if gate.kind == .input {
                Toggle("Værdi: \(gate.isHigh == true ? "1" : "0")", isOn: Binding(
                    get: { gate.isHigh == true },
                    set: { if $0 != (gate.isHigh == true) { editor.toggleInput(id: gate.id) } }
                ))
                Text("Klik på indgangen med Vælg-værktøjet for at skifte mellem 0 og 1. Indgange med samme navn er det samme signal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Værdi", value: editor.logicValue(of: gate).map { $0 ? "1" : "0" } ?? "ukendt")
            }
        }
    }

    /// A block's input or output names, one per line.
    private func pinEditor(_ title: String, names: [String]?, set: @escaping ([String]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: Binding(
                get: { (names ?? []).joined(separator: "\n") },
                set: { set(LogicGate.pinNames(from: $0)) }
            ))
            .font(.body.monospaced())
            .frame(minHeight: 80)
            .scrollContentBackground(.hidden)
            .background(.background.secondary, in: .rect(cornerRadius: 6))
        }
    }
}

// MARK: - Boolean expressions

/// A Boolean expression with lines over what is inverted, like on paper.
struct BoolExprView: View {
    let expression: BoolExpr
    var prefix = ""
    var font: Font = .system(.title3, design: .serif)

    private static let barSpacing: CGFloat = 3

    var body: some View {
        let pieces = expression.pieces
        // How high each line lies: above every line under it.
        var levels: [Int: Int] = [:]
        for piece in pieces {
            for (index, bar) in piece.bars.enumerated() {
                levels[bar] = max(levels[bar] ?? 0, piece.bars.count - index)
            }
        }
        let top = CGFloat(levels.values.max() ?? 0) * Self.barSpacing
        return HStack(spacing: 0) {
            if !prefix.isEmpty {
                Text(prefix).font(font)
            }
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                Text(piece.text)
                    .font(font)
                    .overlay(alignment: .top) {
                        ZStack(alignment: .top) {
                            ForEach(piece.bars, id: \.self) { bar in
                                Rectangle()
                                    .frame(height: 1.3)
                                    .offset(y: -CGFloat(levels[bar] ?? 1) * Self.barSpacing + 2)
                            }
                        }
                    }
            }
        }
        .padding(.top, top)
        .fixedSize()
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(prefix + expression.text)
    }
}

// MARK: - Truth tables

/// A truth table: the row number, the inputs and one or more output columns.
/// With `onTap`, the first output's cells are buttons (the calculator).
/// With `onMoveVariable` / `onMoveOutput`, columns can be dragged to another
/// place (or moved from their context menu).
struct TruthTableGrid: View {
    let variables: [String]
    let outputs: [(name: String, values: [String])]
    var highlighted: Int?
    /// The m range (see `RowNumbering`); `nil` shows every row.
    var range: ClosedRange<Int>?
    var onTap: ((Int) -> Void)?
    var onMoveVariable: ((Int, Int) -> Void)?
    var onMoveOutput: ((Int, Int) -> Void)?

    var body: some View {
        let rows = RowNumbering.rows(variables: variables.count, range: range)
        Grid(alignment: .center, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                header("m").foregroundStyle(.secondary)
                ForEach(Array(variables.enumerated()), id: \.offset) { index, name in
                    movable(header(name), kind: "in", index: index, count: variables.count, move: onMoveVariable)
                }
                ForEach(Array(outputs.enumerated()), id: \.offset) { index, output in
                    movable(header(output.name), kind: "out", index: index, count: outputs.count, move: onMoveOutput)
                        .background(index == highlighted ? Color.accentColor.opacity(0.12) : .clear)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(rows, id: \.row) { row, number in
                GridRow {
                    cell("\(number)").foregroundStyle(.secondary)
                    ForEach(0..<variables.count, id: \.self) { index in
                        cell(row >> (variables.count - 1 - index) & 1 == 1 ? "1" : "0")
                    }
                    ForEach(Array(outputs.enumerated()), id: \.offset) { index, output in
                        let value = output.values.indices.contains(row) ? output.values[row] : "?"
                        if index == 0, let onTap {
                            Button { onTap(row) } label: {
                                Text(value)
                                    .font(.body.monospaced().weight(.semibold))
                                    .foregroundStyle(value == "1" ? Color.accentColor : value == "X" ? .orange : .primary)
                                    .frame(width: 44, height: 24)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                                    .padding(.vertical, 1)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Klik for at skifte mellem 0, 1 og X")
                            .accessibilityLabel("Række \(row): \(value)")
                        } else {
                            cell(value)
                                .fontWeight(.semibold)
                                .foregroundStyle(value == "1" ? Color.accentColor : .primary)
                                .background(index == highlighted ? Color.accentColor.opacity(0.08) : .clear)
                        }
                    }
                }
                .background(number % 2 != 0 ? Color.secondary.opacity(0.06) : .clear)
            }
        }
        .fixedSize()
        if rows.isEmpty {
            Text("Ingen rækker ligger i m-området.")
                .foregroundStyle(.secondary)
        }
    }

    /// A column header that can be dragged onto another of its kind, and
    /// moved from its context menu.
    @ViewBuilder
    private func movable(_ header: some View, kind: String, index: Int, count: Int, move: ((Int, Int) -> Void)?) -> some View {
        if let move, count > 1 {
            header
                .contentShape(Rectangle())
                .draggable("\(kind):\(index)")
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, item.hasPrefix(kind + ":"),
                          let source = Int(item.dropFirst(kind.count + 1)), source != index else { return false }
                    move(source, index)
                    return true
                }
                .contextMenu {
                    Button("Flyt først", systemImage: "arrow.left.to.line") { move(index, 0) }
                        .disabled(index == 0)
                    Button("Flyt til venstre", systemImage: "arrow.left") { move(index, index - 1) }
                        .disabled(index == 0)
                    Button("Flyt til højre", systemImage: "arrow.right") { move(index, index + 1) }
                        .disabled(index == count - 1)
                    Button("Flyt sidst", systemImage: "arrow.right.to.line") { move(index, count - 1) }
                        .disabled(index == count - 1)
                }
                .help("Træk for at flytte kolonnen, eller højreklik")
        } else {
            header
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.body.weight(.semibold))
            .frame(minWidth: 34)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    private func cell(_ text: String) -> some View {
        Text(text)
            .font(.body.monospaced())
            .frame(minWidth: 34)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
    }
}

// MARK: - Karnaugh maps

/// A Karnaugh map with the groups of an analysis drawn around their cells.
struct KarnaughMapView: View {
    let analysis: LogicAnalysis
    let map: KarnaughMap

    @Environment(\.colorScheme) private var colorScheme

    private let cellSize: CGFloat = 40
    private let headerWidth: CGFloat = 54
    private let headerHeight: CGFloat = 40

    var body: some View {
        let rows = map.cells.count
        let columns = map.cells.first?.count ?? 0
        let width = headerWidth + CGFloat(columns) * cellSize + 2
        let height = headerHeight + CGFloat(rows) * cellSize + 2
        let theme = SheetTheme(isDark: colorScheme == .dark)
        Canvas { context, _ in
            let grid = CGRect(x: headerWidth, y: headerHeight, width: CGFloat(columns) * cellSize, height: CGFloat(rows) * cellSize)
            // The corner: row variables bottom left, column variables top right.
            var diagonal = Path()
            diagonal.move(to: CGPoint(x: 4, y: 4))
            diagonal.addLine(to: CGPoint(x: headerWidth, y: headerHeight))
            context.stroke(diagonal, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            context.draw(Text(map.rowVariables.joined()).font(.callout.weight(.semibold)), at: CGPoint(x: 6, y: headerHeight - 4), anchor: .bottomLeading)
            context.draw(Text(map.columnVariables.joined()).font(.callout.weight(.semibold)), at: CGPoint(x: headerWidth - 4, y: 4), anchor: .topTrailing)

            for (index, label) in map.columnLabels.enumerated() {
                context.draw(Text(label).font(.callout.monospaced()).foregroundStyle(.secondary),
                             at: CGPoint(x: grid.minX + (CGFloat(index) + 0.5) * cellSize, y: headerHeight - 6), anchor: .bottom)
            }
            for (index, label) in map.rowLabels.enumerated() {
                context.draw(Text(label).font(.callout.monospaced()).foregroundStyle(.secondary),
                             at: CGPoint(x: headerWidth - 6, y: grid.minY + (CGFloat(index) + 0.5) * cellSize), anchor: .trailing)
            }

            var lines = Path()
            for row in 0...rows {
                lines.move(to: CGPoint(x: grid.minX, y: grid.minY + CGFloat(row) * cellSize))
                lines.addLine(to: CGPoint(x: grid.maxX, y: grid.minY + CGFloat(row) * cellSize))
            }
            for column in 0...columns {
                lines.move(to: CGPoint(x: grid.minX + CGFloat(column) * cellSize, y: grid.minY))
                lines.addLine(to: CGPoint(x: grid.minX + CGFloat(column) * cellSize, y: grid.maxY))
            }
            context.stroke(lines, with: .color(.secondary.opacity(0.5)), lineWidth: 1)

            for (index, group) in analysis.groups.enumerated() {
                let color = Color(theme.groupColor(index))
                let inset = 3 + CGFloat(index % 4) * 3
                for block in map.blocks(for: group.implicant) {
                    let rect = CGRect(
                        x: grid.minX + CGFloat(block.column) * cellSize, y: grid.minY + CGFloat(block.row) * cellSize,
                        width: CGFloat(block.columns) * cellSize, height: CGFloat(block.rows) * cellSize
                    ).insetBy(dx: inset, dy: inset)
                    let shape = Path(roundedRect: rect, cornerRadius: 9)
                    context.fill(shape, with: .color(color.opacity(0.12)))
                    context.stroke(shape, with: .color(color), lineWidth: 2)
                }
            }

            for (row, cells) in map.cells.enumerated() {
                for (column, minterm) in cells.enumerated() {
                    let value = analysis.values[minterm]
                    let center = CGPoint(x: grid.minX + (CGFloat(column) + 0.5) * cellSize, y: grid.minY + (CGFloat(row) + 0.5) * cellSize)
                    context.draw(
                        Text(value.rawValue).font(.title3.monospaced().weight(value == .zero ? .regular : .semibold))
                            .foregroundStyle(value == .zero ? Color.secondary : value == .dontCare ? .orange : .primary),
                        at: center
                    )
                    context.draw(Text("\(minterm)").font(.system(size: 8)).foregroundStyle(.tertiary),
                                 at: CGPoint(x: center.x + cellSize / 2 - 4, y: center.y + cellSize / 2 - 3), anchor: .bottomTrailing)
                }
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement()
        .accessibilityLabel("Karnaugh-kort for \(analysis.output) med \(analysis.groups.count) grupper")
    }
}

// MARK: - The analysis

/// The smallest expression for a truth table column, the gates it needs,
/// the Karnaugh map with its groups and the steps that lead there.
struct LogicAnalysisView: View {
    let analysis: LogicAnalysis
    @Binding var form: LogicForm

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Form", selection: $form) {
                ForEach(LogicForm.allCases) { form in
                    Text(form.shortName).tag(form)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                Text("Mindste udtryk").font(.headline)
                BoolExprView(expression: analysis.expression, prefix: "\(analysis.output) = ")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Du skal bruge").font(.headline)
                // The drawing may use one gate (NAND, XOR, …) for what the
                // expression writes with several.
                if let drawn = analysis.drawnExpression, drawn != analysis.expression {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Tegnes som")
                            .foregroundStyle(.secondary)
                        BoolExprView(expression: drawn, prefix: "\(analysis.output) = ", font: .system(.body, design: .serif))
                    }
                }
                if analysis.gateCounts.isEmpty {
                    Text(analysis.isConstant ? "Ingen gates – udgangen er konstant." : "Ingen gates – udgangen forbindes direkte til indgangen.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(analysis.gateCounts, id: \.self) { count in
                        Label(count.text, systemImage: "square.on.square")
                    }
                }
            }

            if let map = analysis.map {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Karnaugh-kort").font(.headline)
                    ScrollView(.horizontal) {
                        KarnaughMapView(analysis: analysis, map: map)
                    }
                }
            } else if analysis.variables.count > KarnaughMap.variableRange.upperBound {
                Text("Karnaugh-kort tegnes for 2–4 indgange. Med \(analysis.variables.count) indgange er udtrykket fundet med Quine–McCluskey.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Sådan findes udtrykket").font(.headline)
                ForEach(Array(analysis.steps.enumerated()), id: \.offset) { _, step in
                    stepView(step)
                }
            }
        }
    }

    private func stepView(_ step: LogicStep) -> some View {
        let theme = SheetTheme(isDark: colorScheme == .dark)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let group = step.group {
                Circle()
                    .fill(Color(theme.groupColor(group)))
                    .frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 4) {
                UserGuideText(text: step.text)
                if let expression = step.expression {
                    BoolExprView(expression: expression, prefix: step.prefix, font: .system(.body, design: .serif))
                }
            }
        }
    }
}

/// Text with **bold** words, as in the guide and the steps.
struct UserGuideText: View {
    let text: String

    var body: some View {
        UserGuide.runs(text).reduce(Text("")) { result, run in
            Text("\(result)\(Text(run.text).fontWeight(run.bold ? .semibold : .regular))")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The panel

/// The truth table panel of a digital sheet: the truth table of the drawn
/// circuit, and the calculator that finds the gates for a typed truth table.
struct LogicPanelView: View {
    let editor: CircuitEditor
    var isDocked = true
    var onClose: () -> Void = {}

    enum Tab: String, CaseIterable, Identifiable {
        case circuit
        case calculator
        var id: String { rawValue }
        var title: String { self == .circuit ? "Kredsløbet" : "Lommeregner" }
    }

    @State private var tab = Tab.circuit
    @State private var outputIndex = 0
    @State private var circuitForm = LogicForm.sumOfProducts
    @State private var drawFailed = false
    /// The m ranges typed in, e.g. "[-8,7]"; empty shows every row.
    @State private var circuitRange = ""
    @State private var calculatorRange = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Visning", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button("Luk", systemImage: "xmark") {
                    if isDocked { onClose() } else { dismiss() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Luk sandhedstabellen")
            }
            .padding(12)
            .background(.bar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .circuit: circuitContent
                    case .calculator: calculatorContent
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // A line along the top, so the panel doesn't run together with the
        // window's bars above it.
        .overlay(alignment: .top) {
            if isDocked { Divider() }
        }
        #if os(macOS)
        .frame(minWidth: isDocked ? nil : 520, minHeight: isDocked ? nil : 600)
        #endif
    }

    // MARK: The drawn circuit

    @ViewBuilder
    private var circuitContent: some View {
        let network = editor.logicNetwork
        let variables = network.variables
        let outputs = network.outputs
        Text("Sandhedstabel for kredsløbet").font(.title3.bold())
        if variables.isEmpty || outputs.isEmpty {
            Text("Tegn indgange (A, B …) og mindst én udgang (Y), og forbind dem med gates, så står sandhedstabellen her.")
                .foregroundStyle(.secondary)
        } else if variables.count > LogicNetwork.maxVariables {
            Text("Kredsløbet har \(variables.count) indgange. Sandhedstabellen laves for højst \(LogicNetwork.maxVariables).")
                .foregroundStyle(.secondary)
        } else {
            let table = network.truthTable()
            let index = min(outputIndex, table.outputs.count - 1)
            ForEach(network.issues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if table.outputs.count > 1 {
                Picker("Udgang", selection: Binding(get: { index }, set: { outputIndex = $0 })) {
                    ForEach(Array(table.outputs.enumerated()), id: \.offset) { offset, column in
                        Text(column.name).tag(offset)
                    }
                }
            }
            rangeField($circuitRange, variables: table.variables.count)
            ScrollView(.horizontal) {
                TruthTableGrid(
                    variables: table.variables,
                    outputs: table.outputs.map { ($0.name, $0.values.map { $0.map { $0 ? "1" : "0" } ?? "?" }) },
                    highlighted: table.outputs.count > 1 ? index : nil,
                    range: RowNumbering.parse(circuitRange),
                    onMoveVariable: { editor.moveLogicColumn(from: $0, to: $1, isOutput: false) },
                    onMoveOutput: { from, to in
                        // The picked output stays picked.
                        if outputIndex == from { outputIndex = to }
                        else if from < outputIndex, to >= outputIndex { outputIndex -= 1 }
                        else if from > outputIndex, to <= outputIndex { outputIndex += 1 }
                        editor.moveLogicColumn(from: from, to: to, isOutput: true)
                    }
                )
            }
            Text("Træk i en kolonneoverskrift (eller højreklik) for at flytte den. Den første indgang er den mest betydende bit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let column = table.outputs[index]
            if let drawn = network.expression(for: outputs[index]) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Udtrykket fra tegningen").font(.headline)
                    BoolExprView(expression: drawn, prefix: "\(column.name) = ")
                }
            }
            if column.values.allSatisfy({ $0 != nil }) {
                let analysis = LogicAnalysis(
                    variables: table.variables, output: column.name,
                    values: column.values.map { $0 == true ? .one : .zero }, form: circuitForm
                )
                LogicAnalysisView(analysis: analysis, form: $circuitForm)
                if TruthTableSpec(table: table, output: index) != nil {
                    Button("Brug i lommeregneren", systemImage: "arrow.right.square") {
                        if var spec = TruthTableSpec(table: table, output: index) {
                            spec.form = circuitForm
                            editor.calculator = spec
                            tab = .calculator
                        }
                    }
                }
            }
        }
    }

    /// The field for the m range, with what it does.
    private func rangeField(_ text: Binding<String>, variables: Int) -> some View {
        let all = "[0,\((1 << variables) - 1)]"
        let signed = "[\(-(1 << max(0, variables - 1))),\((1 << max(0, variables - 1)) - 1)]"
        let isInvalid = !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty && RowNumbering.parse(text.wrappedValue) == nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("m-område")
                TextField("m-område", text: text, prompt: Text(all))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                if !text.wrappedValue.isEmpty {
                    Button("Alle rækker") { text.wrappedValue = "" }
                }
            }
            Text(isInvalid
                 ? "Skriv to tal, fx \(all) eller \(signed)."
                 : "Kun rækkerne i området vises. Et område under 0, fx \(signed), læser indgangene som et tal med fortegn (2-komplement).")
                .font(.callout)
                .foregroundStyle(isInvalid ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The calculator

    @ViewBuilder
    private var calculatorContent: some View {
        let spec = editor.calculator
        let analysis = spec.analysis
        Text("Lommeregner").font(.title3.bold())
        Text("Skriv den sandhedstabel, kredsløbet skal opfylde. Klik på udgangens felter for at skifte mellem 0, 1 og X (don't care).")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Stepper(value: Binding(
            get: { spec.variables.count },
            set: { editor.calculator.setVariableCount($0) }
        ), in: TruthTableSpec.variableRange) {
            LabeledContent("Indgange", value: "\(spec.variables.count) (\(spec.variables.joined(separator: ", ")))")
        }
        TextField("Udgangens navn", text: Binding(
            get: { spec.outputName },
            set: { editor.calculator.outputName = $0 }
        ))
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 220)
        HStack {
            Button("Alle 0") { editor.calculator.fill(.zero) }
            Button("Alle 1") { editor.calculator.fill(.one) }
            Button("Alle X") { editor.calculator.fill(.dontCare) }
        }
        rangeField($calculatorRange, variables: spec.variables.count)
        ScrollView(.horizontal) {
            TruthTableGrid(
                variables: spec.variables,
                outputs: [(analysis.output, spec.values.map(\.rawValue))],
                range: RowNumbering.parse(calculatorRange),
                onTap: { editor.calculator.cycle(row: $0) },
                onMoveVariable: { editor.calculator.moveVariable(from: $0, to: $1) }
            )
        }
        LogicAnalysisView(analysis: analysis, form: Binding(
            get: { editor.calculator.form },
            set: { editor.calculator.form = $0 }
        ))
        VStack(alignment: .leading, spacing: 6) {
            Button("Tegn kredsløbet på arket", systemImage: "square.and.pencil") {
                drawFailed = !editor.insertCircuit(for: analysis)
            }
            .buttonStyle(.borderedProminent)
            .disabled(analysis.isConstant)
            if analysis.isConstant {
                Text("Udgangen er konstant, så der er ingen gates at tegne.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if drawFailed {
                Text("Kredsløbet har for mange grupper til at blive tegnet (højst \(GateKind.inputRange.upperBound)).")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .onChange(of: spec) { drawFailed = false }
    }
}

#Preview("Digitalt ark") {
    let editor = CircuitEditor()
    editor.chooseMode(.digital)
    var spec = TruthTableSpec()
    for row in [1, 3, 4, 6] { spec.setValue(.one, row: row) }
    editor.calculator = spec
    editor.insertCircuit(for: spec.analysis)
    // A few inverted terminals, as with the inverter tool.
    if let and = editor.circuit.gates.first(where: { $0.kind == .and }) {
        editor.updateGate(id: and.id) { $0.toggleInversion(.input(1)) }
    }
    if let or = editor.circuit.gates.first(where: { $0.kind == .or }) {
        editor.updateGate(id: or.id) { $0.toggleInversion(.output) }
    }
    editor.tool = .invert
    editor.selection = nil
    return HStack(spacing: 0) {
        SchematicCanvas(editor: editor)
        Divider()
        LogicPanelView(editor: editor)
            .frame(width: 460)
    }
    .frame(width: 1100, height: 760)
}

#Preview("Startside") {
    StartView(editor: CircuitEditor())
        .frame(width: 900, height: 600)
}
