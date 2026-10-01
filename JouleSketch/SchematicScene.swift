#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// MARK: - Primitives

/// A color as red, green, blue and opacity from 0 to 1.
nonisolated struct SceneColor: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(white: Double, _ a: Double = 1) {
        self.init(white, white, white, a)
    }

    func opacity(_ factor: Double) -> SceneColor {
        SceneColor(r, g, b, a * factor)
    }
}

/// One step of a path, in screen points.
nonisolated enum PathOp: Hashable {
    case move(CGPoint)
    case line(CGPoint)
    case close
    /// A circle or ellipse filling the rectangle.
    case ellipse(CGRect)
    case rect(CGRect)
    case roundedRect(CGRect, radius: CGFloat)
}

/// A piece of text in one font: names are made of a base, a lowered
/// subscript and what follows.
nonisolated struct TextRun: Hashable {
    var text: String
    var size: CGFloat
    var weight: Int = 500
    var italic = false
    var color: SceneColor
    /// How far the run is raised (positive) or lowered (negative).
    var baseline: CGFloat = 0
}

/// Something to draw on the sheet. Drawn in order.
nonisolated enum ScenePrimitive: Hashable {
    case stroke([PathOp], color: SceneColor, width: CGFloat, dash: [CGFloat] = [], roundCap: Bool = true)
    case fill([PathOp], color: SceneColor, evenOdd: Bool = false)
    /// Text placed so that the point `anchor` (0…1 of its width and height,
    /// from the top left) of its bounds lies at `point`.
    case text([TextRun], at: CGPoint, anchor: CGPoint)
    /// Small squares of side `size` centered on each point.
    case dots([CGPoint], size: CGFloat, color: SceneColor)
}

/// Common text anchors.
nonisolated enum TextAnchor {
    static let center = CGPoint(x: 0.5, y: 0.5)
    static let top = CGPoint(x: 0.5, y: 0)
    static let bottom = CGPoint(x: 0.5, y: 1)
    static let leading = CGPoint(x: 0, y: 0.5)
    static let topLeading = CGPoint(x: 0, y: 0)
    static let bottomLeading = CGPoint(x: 0, y: 1)
}

// MARK: - Theme

/// The sheet's colors, without SwiftUI. Matches `SchematicTheme`.
nonisolated struct SheetTheme {
    var isDark = false
    var sheet = SceneColor(0.957, 0.953, 0.937)
    /// The system accent color (blue).
    var selection = SceneColor(0.0, 0.478, 1.0)

    var outsidePage: SceneColor { isDark ? SceneColor(white: 0, 0.35) : SceneColor(white: 0, 0.12) }
    var gridMinor: SceneColor { isDark ? SceneColor(white: 1, 0.25) : SceneColor(white: 0, 0.24) }
    var gridMajor: SceneColor { isDark ? SceneColor(white: 1, 0.42) : SceneColor(white: 0, 0.38) }
    var wire: SceneColor { isDark ? SceneColor(0.35, 0.85, 0.5) : SceneColor(0.0, 0.48, 0.24) }
    var component: SceneColor { isDark ? SceneColor(1.0, 0.47, 0.45) : SceneColor(0.62, 0.1, 0.12) }
    var label: SceneColor { isDark ? SceneColor(0.6, 0.82, 1.0) : SceneColor(0.08, 0.33, 0.55) }
    var probe: SceneColor { SceneColor(0.9, 0.45, 0.05) }
    var current: SceneColor { isDark ? SceneColor(0.8, 0.6, 1.0) : SceneColor(0.45, 0.15, 0.7) }
    var power: SceneColor { isDark ? SceneColor(1.0, 0.78, 0.2) : SceneColor(0.78, 0.45, 0.0) }
    var control: SceneColor { isDark ? SceneColor(0.35, 0.85, 0.9) : SceneColor(0.0, 0.45, 0.55) }
    var inherited: SceneColor { isDark ? SceneColor(0.8, 0.55, 1.0) : SceneColor(0.55, 0.2, 0.85) }
    var computed: SceneColor { isDark ? SceneColor(white: 0.62) : SceneColor(white: 0.47) }
    var equivalentSymbol: SceneColor { isDark ? SceneColor(white: 0.58) : SceneColor(white: 0.55) }
    var crosshair: SceneColor { isDark ? SceneColor(white: 0.7) : SceneColor(white: 0.35) }
    static let lit = SceneColor(1, 0.72, 0)

    func penColor(_ index: Int) -> SceneColor {
        switch index {
        case 1: isDark ? SceneColor(1.0, 0.42, 0.4) : SceneColor(0.82, 0.12, 0.12)
        case 2: isDark ? SceneColor(0.4, 0.85, 0.45) : SceneColor(0.1, 0.55, 0.2)
        case 3: isDark ? SceneColor(1.0, 0.7, 0.25) : SceneColor(0.9, 0.5, 0.0)
        case 4: isDark ? SceneColor(0.8, 0.55, 1.0) : SceneColor(0.5, 0.2, 0.8)
        default: isDark ? SceneColor(white: 0.92) : SceneColor(white: 0.1)
        }
    }

    func groupColor(_ index: Int) -> SceneColor {
        let light: [(Double, Double, Double)] = [
            (0.82, 0.1, 0.52), (0.85, 0.45, 0.0), (0.15, 0.4, 0.85),
            (0.5, 0.22, 0.78), (0.0, 0.55, 0.55), (0.55, 0.38, 0.12),
        ]
        let dark: [(Double, Double, Double)] = [
            (1.0, 0.45, 0.78), (1.0, 0.7, 0.25), (0.45, 0.68, 1.0),
            (0.75, 0.55, 1.0), (0.3, 0.85, 0.85), (0.85, 0.68, 0.42),
        ]
        let palette = isDark ? dark : light
        let (red, green, blue) = palette[((index % palette.count) + palette.count) % palette.count]
        return SceneColor(red, green, blue)
    }
}

/// How resistors are drawn, matching the setting of the same name.
nonisolated enum SceneResistorStyle: String {
    /// European: a rectangle.
    case iec
    /// American: a zigzag.
    case ansi
}

// MARK: - Building the scene

/// Turns the editor's circuit and the gesture in progress into primitives,
/// following `SchematicCanvas` and `SymbolRenderer`.
struct SchematicScene {
    let editor: CircuitEditor
    let interaction: SheetInteraction
    var theme = SheetTheme()
    var resistorStyle = SceneResistorStyle.iec
    var showGrid = true
    var studyMode = false
    /// The sheet's size on screen.
    var size: CGSize

    private(set) var primitives: [ScenePrimitive] = []

    private var solution: CircuitSolution { studyMode ? editor.solution.withoutValues : editor.solution }
    private var scale: CGFloat { editor.scale }
    private var offset: CGSize { editor.offset }
    private var spacing: CGFloat { CircuitEditor.gridSpacing }
    private var unit: CGFloat { spacing * scale }
    private var pageWidth: Int { editor.pageSize.x }
    private var pageHeight: Int { editor.pageSize.y }

    private func screenPoint(_ grid: GridPoint) -> CGPoint { interaction.screenPoint(grid) }
    private func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * unit + offset.width, y: p.y * unit + offset.height) }
    private func worldPoint(_ p: CGPoint) -> CGPoint { interaction.worldPoint(p) }

    /// Opacity applied to what's drawn while it's set (for previews).
    private var opacity: Double = 1

    mutating func build() -> [ScenePrimitive] {
        primitives = []
        drawPage()
        if showGrid { drawGrid() }
        drawGroupAreas()
        drawCircuit()
        drawExcludedAreas()
        drawGroupHandles()
        drawStrokes()
        drawEraser()
        drawPreview()
        drawSelectionRect()
        drawCrosshair()
        return primitives
    }

    // MARK: Output helpers

    private mutating func stroke(_ path: [PathOp], _ color: SceneColor, width: CGFloat, dash: [CGFloat] = [], roundCap: Bool = true) {
        primitives.append(.stroke(path, color: color.opacity(opacity), width: width, dash: dash, roundCap: roundCap))
    }

    private mutating func fill(_ path: [PathOp], _ color: SceneColor, evenOdd: Bool = false) {
        primitives.append(.fill(path, color: color.opacity(opacity), evenOdd: evenOdd))
    }

    private mutating func text(_ runs: [TextRun], at point: CGPoint, anchor: CGPoint) {
        let faded = runs.map { run -> TextRun in
            var run = run
            run.color = run.color.opacity(opacity)
            return run
        }
        primitives.append(.text(faded, at: point, anchor: anchor))
    }

    private func circle(_ p: CGPoint, _ radius: CGFloat) -> PathOp {
        .ellipse(CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    }

    private func polyline(_ points: [CGPoint]) -> [PathOp] {
        guard let first = points.first else { return [] }
        return [.move(first)] + points.dropFirst().map { .line($0) }
    }

    private func rect(_ p1: CGPoint, _ p2: CGPoint) -> CGRect {
        CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }

    /// A name like V_{A} or R__eq with its subscript lowered and smaller.
    private func subscriptedName(_ name: String, size: CGFloat, weight: Int = 600, color: SceneColor) -> [TextRun] {
        guard let underscore = name.firstIndex(of: "_") else {
            return [TextRun(text: name, size: size, weight: weight, color: color)]
        }
        let base = String(name[..<underscore])
        let rest = name[name.index(after: underscore)...]
        let sub: String
        var tail = ""
        if rest.first == "_" {
            // "__" subscripts the letters and digits that follow, as in formulas: R__eq → R_eq.
            let script = rest.dropFirst().prefix { $0.isLetter || $0.isNumber }
            sub = String(script)
            tail = String(rest.dropFirst(1 + script.count))
        } else {
            sub = rest.filter { $0 != "{" && $0 != "}" }
        }
        var runs = [
            TextRun(text: base, size: size, weight: weight, color: color),
            TextRun(text: sub, size: size * 0.7, weight: weight, color: color, baseline: -size * 0.25),
        ]
        if !tail.isEmpty { runs.append(TextRun(text: tail, size: size, weight: weight, color: color)) }
        return runs
    }

    // MARK: Page and grid

    private mutating func drawPage() {
        let a = screenPoint(GridPoint(x: 0, y: 0))
        let b = screenPoint(GridPoint(x: pageWidth, y: pageHeight))
        let page = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        fill([.rect(CGRect(origin: .zero, size: size)), .rect(page)], theme.outsidePage, evenOdd: true)
        stroke([.rect(page)], theme.gridMajor, width: 1)
    }

    private mutating func drawGrid() {
        // Skip dots when zoomed far out so the sheet doesn't turn grey.
        var step = 1
        while unit * CGFloat(step) < 10 { step *= 2 }

        let topLeft = worldPoint(.zero)
        let bottomRight = worldPoint(CGPoint(x: size.width, y: size.height))
        let minX = max(0, Int((topLeft.x / spacing).rounded(.down)) / step * step - step)
        let maxX = min(pageWidth, Int((bottomRight.x / spacing).rounded(.up)))
        let minY = max(0, Int((topLeft.y / spacing).rounded(.down)) / step * step - step)
        let maxY = min(pageHeight, Int((bottomRight.y / spacing).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }

        var minor: [CGPoint] = []
        var major: [CGPoint] = []
        for gx in stride(from: minX, through: maxX, by: step) {
            for gy in stride(from: minY, through: maxY, by: step) {
                let p = screenPoint(GridPoint(x: gx, y: gy))
                if gx % 10 == 0 || gy % 10 == 0 { major.append(p) } else { minor.append(p) }
            }
        }
        primitives.append(.dots(minor, size: 1.5, color: theme.gridMinor))
        primitives.append(.dots(major, size: 2.5, color: theme.gridMajor))
    }

    // MARK: Circuit

    private mutating func drawCircuit() {
        let circuit = editor.circuit
        let lineWidth = max(1, 2 * scale)

        for wire in circuit.wires {
            let color = editor.isSelected(.wire(wire.id)) ? theme.selection : theme.wire
            stroke(polyline(wire.points.map(screenPoint)), color, width: lineWidth)
            for (index, segment) in wire.segments.enumerated() where editor.isSelected(.wireSegment(wire.id, index)) {
                stroke([.move(screenPoint(segment.0)), .line(screenPoint(segment.1))], theme.selection, width: lineWidth * 1.5)
            }
        }

        for component in circuit.components {
            let isSelected = editor.isSelected(.component(component.id))
            let groupColor = editor.equivalentColorIndex(ofResistor: component.id).map(theme.groupColor)
            drawComponentWithLabels(component, color: isSelected ? theme.selection : groupColor ?? theme.component)
        }

        for component in circuit.components where component.isPowerShown {
            drawPowerCircle(around: component)
        }

        for equivalent in circuit.equivalents {
            drawEquivalent(equivalent)
        }

        for ground in circuit.grounds {
            let color = editor.isSelected(.ground(ground.id)) ? theme.selection : theme.component
            drawGround(at: ground.position, rotation: ground.rotation, color: color)
        }

        let dotRadius = max(2.5, unit * 0.2)
        let junctions = circuit.junctions.map { circle(screenPoint($0), dotRadius) }
        if !junctions.isEmpty { fill(junctions, theme.wire) }

        for arrow in circuit.currents {
            guard let placement = circuit.placement(of: arrow) else { continue }
            let color = editor.isSelected(.currentArrow(arrow.id)) ? theme.selection : theme.current
            drawCurrentArrow(arrow, at: screen(placement.point), direction: placement.direction, color: color)
        }

        drawSenseMarkers()

        for marker in circuit.meshMarkers {
            let color = editor.isSelected(.meshMarker(marker.id)) ? theme.selection : theme.current
            drawMeshMarker(at: screenPoint(marker.position), name: marker.name, clockwise: marker.clockwise, color: color)
        }

        for probe in circuit.probes where probe.isVoltageDrop {
            drawVoltageDrop(probe)
        }
        for probe in circuit.probes where !probe.isVoltageDrop {
            let color = editor.isSelected(.probe(probe.id)) ? theme.selection : theme.probe
            let point = screenPoint(probe.position)
            drawProbe(at: point, color: color)
            let runs = valueLabel(name: probe.name, value: probe.value, computed: solution.probeValues[probe.id], unit: "V", color: color)
            text(runs, at: CGPoint(x: point.x + unit * 0.5, y: point.y - unit * 0.45), anchor: TextAnchor.bottomLeading)
        }
    }

    private mutating func drawComponentWithLabels(_ component: CircuitComponent, color: SceneColor) {
        let a = screenPoint(component.start)
        let b = screenPoint(component.end)
        drawComponent(
            component.kind, from: a, to: b, color: color, lineWidth: max(1, 2 * scale),
            // A conducting LED is drawn lit.
            isLit: component.kind == .led && solution.diodeConducts[component.id] == true
        )

        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let size = max(7, unit * 0.6)
        let name = subscriptedName(component.name, size: size, weight: 500, color: theme.label)
        // A value the calculation filled in is shown in grey italics; one given
        // by a "!name := …" line in a text box in purple.
        var value: [TextRun]
        if component.value == nil, let computed = solution.componentValues[component.id] {
            value = [TextRun(text: SIValue.format(computed, unit: component.kind.displayUnit), size: size, italic: true, color: theme.computed)]
        } else {
            let string = component.value.map { SIValue.format($0, unit: component.kind.displayUnit) }
                ?? (component.kind.isDependent ? "?" : SIValue.format(nil, unit: component.kind.unit))
            value = [TextRun(text: string, size: size, color: editor.isInherited(component.name) ? theme.inherited : theme.label)]
        }
        // Controlled sources show their gain times the controlling quantity, e.g. "2 · VA".
        if component.kind.isDependent {
            value.append(TextRun(text: " · ", size: size, color: theme.label))
            value += subscriptedName(component.controlLabel, size: size, weight: 500, color: theme.label)
        }
        if component.start.y == component.end.y {
            text(name, at: CGPoint(x: mid.x, y: mid.y - unit * 1.1), anchor: TextAnchor.bottom)
            text(value, at: CGPoint(x: mid.x, y: mid.y + unit * 1.1), anchor: TextAnchor.top)
        } else {
            text(name, at: CGPoint(x: mid.x + unit * 1.2, y: mid.y), anchor: TextAnchor.bottomLeading)
            text(value, at: CGPoint(x: mid.x + unit * 1.2, y: mid.y), anchor: TextAnchor.topLeading)
        }
    }

    /// A power circle around the component with "P_R1 = value" at its upper right.
    private mutating func drawPowerCircle(around component: CircuitComponent) {
        let a = screenPoint(component.start)
        let b = screenPoint(component.end)
        let center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let radius = a.distance(to: b) / 2 + unit * 0.6
        let color = editor.isSelected(.component(component.id)) ? theme.selection : theme.power
        fill([circle(center, radius)], theme.power.opacity(0.06))
        stroke([circle(center, radius)], color, width: max(1, 1.5 * scale))

        let size = max(7, unit * 0.6)
        var runs = subscriptedName(component.powerName, size: size, color: color)
        if let power = solution.powerValues[component.id] {
            runs.append(TextRun(text: " = " + SIValue.format(power, unit: "W"), size: size, weight: 600, italic: true, color: theme.computed))
        } else {
            runs.append(TextRun(text: " = " + SIValue.format(nil, unit: "W"), size: size, weight: 600, color: color))
        }
        let corner = CGPoint(x: center.x + radius * 0.72, y: center.y - radius * 0.72)
        text(runs, at: CGPoint(x: corner.x + unit * 0.15, y: corner.y - unit * 0.15), anchor: TextAnchor.bottomLeading)
    }

    private mutating func drawEquivalent(_ equivalent: EquivalentResistance) {
        let a = screenPoint(equivalent.start)
        let b = screenPoint(equivalent.end)
        let isSelected = editor.isSelected(.equivalent(equivalent.id))
        drawComponent(.resistor, from: a, to: b, color: isSelected ? theme.selection : theme.equivalentSymbol, lineWidth: max(1, 2 * scale))

        let color = theme.groupColor(equivalent.colorIndex)
        let size = max(7, unit * 0.6)
        let name = subscriptedName(equivalent.name, size: size, color: color)
        let valueText: String = if !studyMode, case .value(let resistance, _) = editor.equivalentResults[equivalent.id] {
            SIValue.format(resistance, unit: "Ω")
        } else {
            SIValue.format(nil, unit: "Ω")
        }
        let value = [TextRun(text: valueText, size: size, weight: 600, color: color)]
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        if equivalent.start.y == equivalent.end.y {
            text(name, at: CGPoint(x: mid.x, y: mid.y - unit * 1.1), anchor: TextAnchor.bottom)
            text(value, at: CGPoint(x: mid.x, y: mid.y + unit * 1.1), anchor: TextAnchor.top)
        } else {
            text(name, at: CGPoint(x: mid.x + unit * 1.2, y: mid.y), anchor: TextAnchor.bottomLeading)
            text(value, at: CGPoint(x: mid.x + unit * 1.2, y: mid.y), anchor: TextAnchor.topLeading)
        }
    }

    private mutating func drawCurrentArrow(_ arrow: CurrentArrow, at point: CGPoint, direction: CGPoint, color: SceneColor) {
        drawArrowhead(at: point, direction: direction, size: unit * 0.9, color: color)
        let runs = valueLabel(name: arrow.name, value: arrow.value, computed: solution.currentValues[arrow.id], unit: "A", color: color)
        if abs(direction.x) > abs(direction.y) {
            text(runs, at: CGPoint(x: point.x, y: point.y - unit * 0.55), anchor: TextAnchor.bottom)
        } else {
            text(runs, at: CGPoint(x: point.x + unit * 0.55, y: point.y), anchor: TextAnchor.leading)
        }
    }

    private mutating func drawGround(at position: GridPoint, rotation: Int, color: SceneColor) {
        let direction = Ground(position: position, rotation: rotation).direction
        let point = screenPoint(position)
        let d = CGPoint(x: direction.x, y: direction.y)
        let normal = CGPoint(x: -d.y, y: d.x)
        func at(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(
                x: point.x + d.x * along * unit + normal.x * across * unit,
                y: point.y + d.y * along * unit + normal.y * across * unit
            )
        }
        var path: [PathOp] = [.move(point), .line(at(0.7, 0))]
        for (along, halfWidth) in [(0.7, 0.6), (0.95, 0.38), (1.2, 0.16)] as [(CGFloat, CGFloat)] {
            path += [.move(at(along, -halfWidth)), .line(at(along, halfWidth))]
        }
        stroke(path, color, width: max(1, 2 * scale))
    }

    private mutating func drawExcludedAreas() {
        var rects = editor.circuit.excludedAreas.map { area in
            (rect: rect(screenPoint(area.from), screenPoint(area.to)), isSelected: editor.isSelected(.excludedArea(area.id)))
        }
        if let draft = interaction.exclusionDraft {
            rects.append((rect(screenPoint(interaction.snap(draft.start)), screenPoint(interaction.snap(draft.current))), false))
        }
        let size = max(7, unit * 0.5)
        for (rect, isSelected) in rects {
            let path: [PathOp] = [.roundedRect(rect, radius: 4)]
            fill(path, theme.sheet.opacity(0.55))
            let color = isSelected ? theme.selection : theme.computed
            stroke(path, color, width: isSelected ? 2 : 1.2, dash: [6, 4], roundCap: false)
            text([TextRun(text: "Udeladt af beregning", size: size, color: color)], at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), anchor: TextAnchor.topLeading)
        }
    }

    private mutating func drawGroupAreas() {
        let size = max(8, unit * 0.6)
        for group in editor.circuit.groupAreas {
            let color = SceneColor(group.red, group.green, group.blue)
            let isSelected = editor.isSelected(.groupArea(group.id))
            let rect = rect(screenPoint(group.from), screenPoint(group.to))
            let path: [PathOp] = [.roundedRect(rect, radius: 6)]
            fill(path, color.opacity(theme.isDark ? 0.16 : 0.09))
            stroke(path, isSelected ? theme.selection : color.opacity(0.55), width: isSelected ? 2 : 1)
            text(
                [TextRun(text: group.name, size: size, weight: 600, color: isSelected ? theme.selection : color)],
                at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), anchor: TextAnchor.topLeading
            )
        }
    }

    private mutating func drawGroupHandles() {
        guard case .groupArea(let id) = editor.selection, let group = editor.groupArea(id: id) else { return }
        let radius = max(4, unit * 0.22)
        for handle in GroupArea.Handle.all {
            let p = interaction.handleScreenPoint(group, handle)
            fill([circle(p, radius)], theme.sheet)
            stroke([circle(p, radius)], theme.selection, width: 1.5)
        }
    }

    private mutating func drawVoltageDrop(_ probe: Probe) {
        guard let negative = probe.negative, let label = editor.voltageDropLabelPosition(of: probe) else { return }
        let a = screenPoint(probe.position)
        let b = screenPoint(negative)
        let labelPoint = screen(label)
        drawMarkerPair(
            plus: a, minus: b, label: labelPoint,
            plusColor: editor.isSelected(.probe(probe.id)) ? theme.selection : theme.probe,
            minusColor: editor.isSelected(.probeMinus(probe.id)) ? theme.selection : theme.probe,
            lineColor: theme.probe
        )

        let isLabelSelected = editor.isSelected(.probeLabel(probe.id))
        let color = isLabelSelected ? theme.selection : theme.probe
        let size = max(7, unit * 0.6)
        var runs = subscriptedName(probe.name, size: size, color: color)
        if let value = probe.value {
            let valueColor = isLabelSelected ? color : (editor.isInherited(probe.name) ? theme.inherited : color)
            runs.append(TextRun(text: " = " + SIValue.format(value, unit: "V"), size: size, weight: 600, color: valueColor))
        } else if let computed = solution.probeValues[probe.id] {
            runs.append(TextRun(text: " = " + SIValue.format(computed, unit: "V"), size: size, weight: 600, italic: true, color: theme.computed))
        }
        text(runs, at: labelPoint, anchor: TextAnchor.center)
    }

    private mutating func drawMeshMarker(at point: CGPoint, name: String, clockwise: Bool, color: SceneColor) {
        drawMeshArrow(at: point, radius: unit * 1.1, clockwise: clockwise, color: color, lineWidth: max(1, 1.8 * scale))
        let size = max(8, unit * 0.7)
        text(subscriptedName(name, size: size, color: color), at: point, anchor: TextAnchor.center)
    }

    /// + and − markers with a dashed line from each to the label, like a bracket.
    private mutating func drawMarkerPair(
        plus a: CGPoint, minus b: CGPoint, label labelPoint: CGPoint,
        plusColor: SceneColor, minusColor: SceneColor, lineColor: SceneColor
    ) {
        let radius = max(5, unit * 0.42)
        let gap = max(9, unit * 0.75)
        let markersStacked = abs(a.y - b.y) >= abs(a.x - b.x)
        var line: [PathOp] = []
        for end in [a, b] {
            let corner = markersStacked ? CGPoint(x: labelPoint.x, y: end.y) : CGPoint(x: end.x, y: labelPoint.y)
            line += polyline(trimmed([labelPoint, corner, end], start: gap, end: radius))
        }
        stroke(line, lineColor.opacity(0.8), width: 1.2, dash: [5, 4], roundCap: false)
        for (point, color, isPlus) in [(a, plusColor, true), (b, minusColor, false)] {
            drawSignMarker(at: point, radius: radius, color: color, isPlus: isPlus)
        }
    }

    private mutating func drawSignMarker(at point: CGPoint, radius: CGFloat, color: SceneColor, isPlus: Bool) {
        fill([circle(point, radius)], theme.sheet)
        stroke([circle(point, radius)], color, width: 1.5)
        let size = radius * 0.5
        var sign: [PathOp] = [.move(CGPoint(x: point.x - size, y: point.y)), .line(CGPoint(x: point.x + size, y: point.y))]
        if isPlus {
            sign += [.move(CGPoint(x: point.x, y: point.y - size)), .line(CGPoint(x: point.x, y: point.y + size))]
        }
        stroke(sign, color, width: 1.5)
    }

    private mutating func drawSenseMarkers() {
        let circuit = editor.circuit
        let size = max(7, unit * 0.6)
        let radius = max(5, unit * 0.42)

        for component in circuit.components where component.kind.isVoltageControlled {
            guard let plus = circuit.sense(of: component.id, .plus),
                  let minus = circuit.sense(of: component.id, .minus) else { continue }
            let a = screen(plus.point)
            let b = screen(minus.point)
            let labelPoint = editor.senseLabelPosition(of: component).map(screen)
                ?? CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let gap = max(9, unit * 0.75)
            var line: [PathOp] = []
            let markersStacked = abs(a.y - b.y) >= abs(a.x - b.x)
            for end in [a, b] {
                let corner = markersStacked ? CGPoint(x: labelPoint.x, y: end.y) : CGPoint(x: end.x, y: labelPoint.y)
                line += polyline(trimmed([labelPoint, corner, end], start: gap, end: radius))
            }
            stroke(line, theme.control.opacity(0.8), width: 1.2, dash: [5, 4], roundCap: false)

            let labelColor = editor.isSelected(.senseLabel(component.id)) ? theme.selection : theme.control
            text(subscriptedName(component.controlLabel, size: size, color: labelColor), at: labelPoint, anchor: TextAnchor.center)

            for (marker, point) in [(plus, a), (minus, b)] {
                let color = editor.isSelected(.sense(marker.id)) ? theme.selection : theme.control
                drawSignMarker(at: point, radius: radius, color: color, isPlus: marker.kind == .plus)
            }
        }

        for component in circuit.components where component.kind.isCurrentControlled {
            guard let marker = circuit.sense(of: component.id, .current) else { continue }
            let point = screen(marker.point)
            let color = editor.isSelected(.sense(marker.id)) ? theme.selection : theme.control
            let arrow = circuit.currentArrow(for: marker)
            let placement = arrow.flatMap { circuit.placement(of: $0) }
            // Not on a wire yet: dashed outline and a horizontal arrow.
            fill([circle(point, radius)], theme.sheet)
            stroke([circle(point, radius)], color, width: 1.5, dash: placement == nil ? [3, 2] : [], roundCap: false)
            var direction = placement?.direction ?? CGPoint(x: marker.flipped ? -1 : 1, y: 0)
            let length = hypot(direction.x, direction.y)
            if length > 0 { direction = CGPoint(x: direction.x / length, y: direction.y / length) }
            drawArrowhead(at: point, direction: direction, size: radius * 1.1, color: color)

            let isVertical = abs(direction.y) > abs(direction.x)
            let labelPoint = isVertical
                ? CGPoint(x: point.x + radius + 3, y: point.y)
                : CGPoint(x: point.x, y: point.y - radius - 2)
            text(subscriptedName(component.controlLabel, size: size, color: color), at: labelPoint, anchor: isVertical ? TextAnchor.leading : TextAnchor.bottom)
        }
    }

    /// A polyline shortened by `start` at its beginning and `end` at its end.
    private func trimmed(_ points: [CGPoint], start: CGFloat, end: CGFloat) -> [CGPoint] {
        func cut(_ points: [CGPoint], by distance: CGFloat) -> [CGPoint] {
            var remaining = distance
            var result = points
            while result.count >= 2 {
                let length = result[0].distance(to: result[1])
                if length > remaining {
                    let t = remaining / length
                    result[0] = CGPoint(x: result[0].x + (result[1].x - result[0].x) * t, y: result[0].y + (result[1].y - result[0].y) * t)
                    return result
                }
                remaining -= length
                result.removeFirst()
            }
            return []
        }
        let fromStart = cut(points, by: start)
        return Array(cut(fromStart.reversed(), by: end).reversed())
    }

    /// A "Name = value" label, or just the name while the value is unknown.
    private func valueLabel(name: String, value: Double?, computed: Double?, unit valueUnit: String, color: SceneColor) -> [TextRun] {
        let size = max(7, unit * 0.6)
        var runs = subscriptedName(name, size: size, weight: 500, color: color)
        if let value {
            let valueColor = editor.isInherited(name) ? theme.inherited : color
            runs.append(TextRun(text: " = " + SIValue.format(value, unit: valueUnit), size: size, color: valueColor))
        } else if let computed {
            runs.append(TextRun(text: " = " + SIValue.format(computed, unit: valueUnit), size: size, italic: true, color: theme.computed))
        }
        return runs
    }

    // MARK: Drawing in progress

    private mutating func drawSelectionRect() {
        guard case .selectingArea(let start, let current) = interaction.dragMode else { return }
        let r = rect(start, current)
        fill([.rect(r)], theme.selection.opacity(0.1))
        stroke([.rect(r)], theme.selection, width: 1, dash: [4, 3], roundCap: false)
    }

    private mutating func drawPreview() {
        let wireWidth = max(1, 2 * scale)
        let hoverPoint = interaction.hoverPoint

        // The wire being routed: fixed segments solid, the next one faded.
        if editor.isRouting, let last = editor.routing.last {
            stroke(polyline(editor.routing.map(screenPoint)), theme.wire, width: wireWidth)
            let size = max(4, unit * 0.25)
            for point in editor.routing {
                let p = screenPoint(point)
                stroke([.rect(CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))], theme.wire, width: 1)
            }
            if let hoverPoint, hoverPoint != last {
                opacity = 0.55
                stroke(lPath(from: last, to: hoverPoint), theme.wire, width: wireWidth)
                opacity = 1
            }
            return
        }

        // A Req's first point, with a dashed line to where the second would go.
        if editor.tool == .equivalent, let start = editor.pendingEquivalentPoint {
            let a = screenPoint(start)
            if let hoverPoint, hoverPoint != start {
                opacity = 0.55
                stroke([.move(a), .line(screenPoint(hoverPoint))], theme.equivalentSymbol, width: 1.5, dash: [5, 4], roundCap: false)
                opacity = 1
            }
            fill([circle(a, max(4, unit * 0.3))], theme.equivalentSymbol)
            return
        }

        opacity = 0.55
        defer { opacity = 1 }

        // The ground tool shows a ghost where it will be placed.
        if editor.tool == .ground, let point = hoverPoint {
            if case .cancelled = interaction.dragMode { return }
            drawGround(at: point, rotation: editor.placementRotation, color: theme.component)
            return
        }

        // A component tool with a pointer shows a ghost of the tap placement.
        if case .component(let kind) = editor.tool, case .idle = interaction.dragMode, let hoverPoint {
            let (a, b) = editor.defaultTerminals(centeredAt: hoverPoint)
            drawComponent(kind, from: screenPoint(a), to: screenPoint(b), color: theme.component, lineWidth: wireWidth)
            return
        }
        if editor.tool == .mesh, case .idle = interaction.dragMode, let hoverPoint {
            drawMeshMarker(at: screenPoint(hoverPoint), name: editor.circuit.nextMeshName(), clockwise: editor.meshPlacementClockwise, color: theme.current)
            return
        }

        guard case .drawing(let start, let current) = interaction.dragMode else { return }
        switch editor.tool {
        case .wire where interaction.drawingRectangle:
            guard start.x != current.x, start.y != current.y else { return }
            stroke([.rect(rect(screenPoint(start), screenPoint(current)))], theme.wire, width: wireWidth)
        case .wire:
            guard start != current else { return }
            stroke(lPath(from: start, to: current), theme.wire, width: wireWidth)
        case .component(let kind):
            let (a, b) = interaction.componentTerminals(start: start, current: current)
            drawComponent(kind, from: screenPoint(a), to: screenPoint(b), color: theme.component, lineWidth: wireWidth)
        case .probe:
            if interaction.placingVoltageDrop, start != current {
                let a = screenPoint(start), b = screenPoint(current)
                let stacked = abs(a.y - b.y) >= abs(a.x - b.x)
                let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let label = stacked ? CGPoint(x: middle.x - 1.5 * unit, y: middle.y) : CGPoint(x: middle.x, y: middle.y - 1.5 * unit)
                drawMarkerPair(plus: a, minus: b, label: label, plusColor: theme.probe, minusColor: theme.probe, lineColor: theme.probe)
            } else {
                drawProbe(at: screenPoint(current), color: theme.probe)
            }
        case .mesh:
            drawMeshMarker(at: screenPoint(current), name: editor.circuit.nextMeshName(), clockwise: editor.meshPlacementClockwise, color: theme.current.opacity(0.5))
        case .groupArea:
            guard start.x != current.x, start.y != current.y else { return }
            let (red, green, blue) = GroupArea.palette[editor.circuit.groupAreas.count % GroupArea.palette.count]
            let color = SceneColor(red, green, blue)
            let path: [PathOp] = [.roundedRect(rect(screenPoint(start), screenPoint(current)), radius: 6)]
            fill(path, color.opacity(0.1))
            stroke(path, color, width: 1.5, dash: [6, 4], roundCap: false)
        case .power:
            // The circle follows the pointer rather than the grid.
            guard let draft = interaction.powerDraft else { return }
            let path: [PathOp] = [.ellipse(rect(draft.start, draft.current))]
            fill(path, theme.power.opacity(0.08))
            stroke(path, theme.power, width: 1.5, dash: [6, 4], roundCap: false)
        case .select, .current, .ground, .equivalent, .text:
            break
        }
    }

    /// An L-shaped path, horizontal first, matching how wires are created.
    private func lPath(from start: GridPoint, to end: GridPoint) -> [PathOp] {
        [.move(screenPoint(start)), .line(screenPoint(GridPoint(x: end.x, y: start.y))), .line(screenPoint(end))]
    }

    private mutating func drawStrokes() {
        let pending = Stroke(points: interaction.currentStroke, color: editor.penColor, size: editor.penSize)
        for line in editor.circuit.strokes + [pending] where !line.xs.isEmpty {
            stroke(polyline(line.points.map(screen)), theme.penColor(line.color), width: max(0.5, line.width * scale))
        }
    }

    private mutating func drawEraser() {
        guard editor.isDrawing, editor.isErasing, let location = interaction.eraserLocation else { return }
        let r = SheetInteraction.eraserRadius
        fill([circle(location, r)], theme.sheet.opacity(0.5))
        stroke([circle(location, r)], theme.gridMajor, width: 1)
    }

    /// A KiCad-style crosshair marking the grid point the pen will snap to.
    private mutating func drawCrosshair() {
        guard editor.tool != .select, !editor.isDrawing, let hoverPoint = interaction.hoverPoint else { return }
        let p = screenPoint(hoverPoint)
        let arm = max(unit * 4, 40)
        stroke([
            .move(CGPoint(x: p.x - arm, y: p.y)), .line(CGPoint(x: p.x + arm, y: p.y)),
            .move(CGPoint(x: p.x, y: p.y - arm)), .line(CGPoint(x: p.x, y: p.y + arm)),
        ], theme.crosshair, width: 0.75, roundCap: false)

        // A ring shows that a click here will connect and finish the wire, or pick a point for a Req.
        if (editor.tool == .wire && editor.circuit.isConnectionPoint(hoverPoint))
            || (editor.tool == .equivalent && editor.isEquivalentPoint(hoverPoint)) {
            stroke([circle(p, max(6, unit * 0.45))], theme.wire, width: 1.5)
        }
    }

    // MARK: Symbols

    /// A two-terminal component between `a` and `b`, as in `SymbolRenderer`.
    /// The symbol body is centered and 2 grid units long; leads fill the rest.
    private mutating func drawComponent(
        _ kind: ComponentKind, from a: CGPoint, to b: CGPoint, color: SceneColor, lineWidth: CGFloat, isLit: Bool = false
    ) {
        let length = a.distance(to: b)
        guard length > 0 else { return }

        // A local frame where the component runs along +x from `a`.
        let cosine = (b.x - a.x) / length, sine = (b.y - a.y) / length
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: a.x + x * cosine - y * sine, y: a.y + x * sine + y * cosine)
        }

        let center = length / 2
        let halfBody = min(unit, center)

        stroke([.move(p(0, 0)), .line(p(center - halfBody, 0)), .move(p(center + halfBody, 0)), .line(p(length, 0))], color, width: lineWidth)

        switch kind {
        case .resistor:
            switch resistorStyle {
            case .iec:
                let height = unit * 0.8
                let x0 = center - halfBody, x1 = center + halfBody
                stroke([.move(p(x0, -height / 2)), .line(p(x1, -height / 2)), .line(p(x1, height / 2)), .line(p(x0, height / 2)), .close], color, width: lineWidth)
            case .ansi:
                let amplitude = unit * 0.4
                let start = center - halfBody
                let step = halfBody * 2 / 12
                var zigzag: [PathOp] = [.move(p(start, 0))]
                for (index, fraction) in [1, 3, 5, 7, 9, 11].enumerated() {
                    zigzag.append(.line(p(start + step * CGFloat(fraction), index.isMultiple(of: 2) ? -amplitude : amplitude)))
                }
                zigzag.append(.line(p(center + halfBody, 0)))
                stroke(zigzag, color, width: lineWidth)
            }

        case .diode, .led:
            let size = halfBody * 0.6
            let base = center - size
            let tip = center + size
            stroke([.move(p(center - halfBody, 0)), .line(p(base, 0)), .move(p(tip, 0)), .line(p(center + halfBody, 0))], color, width: lineWidth)
            let triangle: [PathOp] = [.move(p(base, -size)), .line(p(tip, 0)), .line(p(base, size)), .close]
            if isLit { fill(triangle, SheetTheme.lit.opacity(0.45)) }
            stroke(triangle, color, width: lineWidth)
            stroke([.move(p(tip, -size)), .line(p(tip, size))], color, width: lineWidth)

            if kind == .led {
                let arrowColor = isLit ? SheetTheme.lit : color
                let head = size * 0.35
                for offset in [-size * 0.45, size * 0.25] {
                    let from = (x: center + offset, y: -size * 1.15)
                    let to = (x: from.x + size * 0.6, y: from.y - size * 0.6)
                    stroke([
                        .move(p(from.x, from.y)), .line(p(to.x, to.y)),
                        .move(p(to.x - head, to.y)), .line(p(to.x, to.y)), .line(p(to.x, to.y + head)),
                    ], arrowColor, width: max(1, lineWidth * 0.75))
                }
            }

        case .voltageSource, .currentSource, .vcvs, .ccvs, .vccs, .cccs:
            if kind.isDependent {
                stroke([.move(p(center - halfBody, 0)), .line(p(center, -halfBody)), .line(p(center + halfBody, 0)), .line(p(center, halfBody)), .close], color, width: lineWidth)
            } else {
                stroke([circle(p(center, 0), halfBody)], color, width: lineWidth)
            }

            if kind.setsVoltage {
                // "+" towards the end terminal, "−" towards the start; always upright.
                let sign = halfBody * (kind.isDependent ? 0.22 : 0.28)
                let offset = halfBody * (kind.isDependent ? 0.42 : 0.48)
                let plus = p(center + offset, 0)
                let minus = p(center - offset, 0)
                stroke([
                    .move(CGPoint(x: plus.x - sign, y: plus.y)), .line(CGPoint(x: plus.x + sign, y: plus.y)),
                    .move(CGPoint(x: plus.x, y: plus.y - sign)), .line(CGPoint(x: plus.x, y: plus.y + sign)),
                    .move(CGPoint(x: minus.x - sign, y: minus.y)), .line(CGPoint(x: minus.x + sign, y: minus.y)),
                ], color, width: lineWidth)
            } else {
                // Arrow pointing towards the end terminal (direction of current).
                let reach = kind.isDependent ? 0.5 : 0.6
                let tail = center - halfBody * reach
                let tip = center + halfBody * reach
                let head = halfBody * 0.3
                stroke([
                    .move(p(tail, 0)), .line(p(tip, 0)),
                    .move(p(tip - head, -head * 0.8)), .line(p(tip, 0)), .line(p(tip - head, head * 0.8)),
                ], color, width: lineWidth)
            }
        }
    }

    /// A filled arrowhead centered on `point`, pointing along `direction` (a unit vector).
    private mutating func drawArrowhead(at point: CGPoint, direction: CGPoint, size: CGFloat, color: SceneColor) {
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let half = size / 2
        let tip = CGPoint(x: point.x + direction.x * half, y: point.y + direction.y * half)
        let base = CGPoint(x: point.x - direction.x * half, y: point.y - direction.y * half)
        let width = size * 0.38
        fill([
            .move(tip),
            .line(CGPoint(x: base.x + normal.x * width, y: base.y + normal.y * width)),
            .line(CGPoint(x: base.x - normal.x * width, y: base.y - normal.y * width)),
            .close,
        ], color)
    }

    /// A curved arrow most of the way round `center`, like one drawn by hand.
    private mutating func drawMeshArrow(at center: CGPoint, radius: CGFloat, clockwise: Bool, color: SceneColor, lineWidth: CGFloat) {
        let start = clockwise ? 100.0 : 80.0
        let end = clockwise ? 350.0 : -170.0
        let steps = 40
        let points = (0...steps).map { step -> CGPoint in
            let angle = (start + (end - start) * Double(step) / Double(steps)) * .pi / 180
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        stroke(polyline(points), color, width: lineWidth)
        let last = end * .pi / 180
        let tip = CGPoint(x: center.x + radius * cos(last), y: center.y + radius * sin(last))
        let sign: Double = clockwise ? 1 : -1
        drawArrowhead(at: tip, direction: CGPoint(x: -sin(last) * sign, y: cos(last) * sign), size: max(6, radius * 0.45), color: color)
    }

    /// A voltage point: a large dot on the node.
    private mutating func drawProbe(at point: CGPoint, color: SceneColor) {
        fill([circle(point, max(4, unit * 0.38))], color)
    }
}
