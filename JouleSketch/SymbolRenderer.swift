import SwiftUI

/// Draws schematic symbols (IEC style) into a `GraphicsContext`.
/// All coordinates are in screen space; `unit` is the on-screen grid spacing.
enum SymbolRenderer {
    /// Draws a two-terminal component between `a` and `b`.
    /// The symbol body is centered and 2 grid units long; leads fill the rest.
    static func drawComponent(
        _ kind: ComponentKind,
        from a: CGPoint,
        to b: CGPoint,
        unit: CGFloat,
        color: Color,
        lineWidth: CGFloat,
        resistorStyle: ResistorStyle = .iec,
        brightness: Double = 0,
        light: Color = litColor,
        waveform: SignalWaveform = .sine,
        isClosed: Bool = false,
        isNormallyClosed: Bool = false,
        in context: GraphicsContext
    ) {
        let length = a.distance(to: b)
        guard length > 0 else { return }

        // Work in a local frame where the component runs along +x from the origin.
        var local = context
        local.translateBy(x: a.x, y: a.y)
        local.rotate(by: .radians(atan2(b.y - a.y, b.x - a.x)))

        let center = length / 2
        let halfBody = min(unit, center)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

        var leads = Path()
        leads.move(to: .zero)
        leads.addLine(to: CGPoint(x: center - halfBody, y: 0))
        leads.move(to: CGPoint(x: center + halfBody, y: 0))
        leads.addLine(to: CGPoint(x: length, y: 0))
        local.stroke(leads, with: .color(color), style: style)

        switch kind {
        case .resistor:
            switch resistorStyle {
            case .iec:
                // European: a rectangle.
                let height = unit * 0.8
                let body = Path(CGRect(x: center - halfBody, y: -height / 2, width: halfBody * 2, height: height))
                local.stroke(body, with: .color(color), style: style)
            case .ansi:
                // American: a zigzag with three peaks on each side.
                let amplitude = unit * 0.4
                let start = center - halfBody
                let step = halfBody * 2 / 12
                var zigzag = Path()
                zigzag.move(to: CGPoint(x: start, y: 0))
                for (index, fraction) in [1, 3, 5, 7, 9, 11].enumerated() {
                    zigzag.addLine(to: CGPoint(x: start + step * CGFloat(fraction), y: index.isMultiple(of: 2) ? -amplitude : amplitude))
                }
                zigzag.addLine(to: CGPoint(x: center + halfBody, y: 0))
                local.stroke(zigzag, with: .color(color), style: style)
            }

        case .diode, .led:
            // A triangle pointing from anode to cathode, with a bar at the cathode.
            let size = halfBody * 0.6
            let base = center - size
            let tip = center + size
            var wires = Path()
            wires.move(to: CGPoint(x: center - halfBody, y: 0))
            wires.addLine(to: CGPoint(x: base, y: 0))
            wires.move(to: CGPoint(x: tip, y: 0))
            wires.addLine(to: CGPoint(x: center + halfBody, y: 0))
            local.stroke(wires, with: .color(color), style: style)

            var triangle = Path()
            triangle.move(to: CGPoint(x: base, y: -size))
            triangle.addLine(to: CGPoint(x: tip, y: 0))
            triangle.addLine(to: CGPoint(x: base, y: size))
            triangle.closeSubpath()
            if brightness > 0 { local.fill(triangle, with: .color(light.opacity(0.45 * brightness))) }
            local.stroke(triangle, with: .color(color), style: style)

            var bar = Path()
            bar.move(to: CGPoint(x: tip, y: -size))
            bar.addLine(to: CGPoint(x: tip, y: size))
            local.stroke(bar, with: .color(color), style: style)

            if kind == .led {
                // Two arrows for the emitted light, bright when the LED is on.
                let arrowColor = brightness > 0 ? light.opacity(0.3 + 0.7 * brightness) : color
                let head = size * 0.35
                for offset in [-size * 0.45, size * 0.25] {
                    let from = CGPoint(x: center + offset, y: -size * 1.15)
                    let to = CGPoint(x: from.x + size * 0.6, y: from.y - size * 0.6)
                    var arrow = Path()
                    arrow.move(to: from)
                    arrow.addLine(to: to)
                    arrow.move(to: CGPoint(x: to.x - head, y: to.y))
                    arrow.addLine(to: to)
                    arrow.addLine(to: CGPoint(x: to.x, y: to.y + head))
                    local.stroke(arrow, with: .color(arrowColor), style: StrokeStyle(lineWidth: max(1, lineWidth * 0.75), lineCap: .round, lineJoin: .round))
                }
            }

        case .toggleSwitch, .pushButton:
            // Two contacts; a switch has an arm hinged at the first, raised
            // when open, and a push button a bridge pressed down onto both.
            let x0 = center - halfBody * 0.7, x1 = center + halfBody * 0.7
            let dot = unit * 0.12
            var path = Path()
            path.move(to: CGPoint(x: center - halfBody, y: 0))
            path.addLine(to: CGPoint(x: x0 - dot, y: 0))
            path.move(to: CGPoint(x: x1 + dot, y: 0))
            path.addLine(to: CGPoint(x: center + halfBody, y: 0))
            for x in [x0, x1] {
                path.addEllipse(in: CGRect(x: x - dot, y: -dot, width: dot * 2, height: dot * 2))
            }
            if kind == .toggleSwitch {
                let reach = x1 - x0
                let angle = isClosed ? 0 : CGFloat.pi / 6
                path.move(to: CGPoint(x: x0, y: 0))
                path.addLine(to: CGPoint(x: x0 + reach * cos(angle), y: -reach * sin(angle)))
            } else {
                // An NC button's bridge rests under the contacts and is pushed
                // away downwards; an NO button's is pushed down onto them.
                let bar: CGFloat = isNormallyClosed
                    ? (isClosed ? dot * 1.3 : unit * 0.5)
                    : (isClosed ? -dot * 1.3 : -unit * 0.5)
                let top = min(bar, 0) - unit * 0.45 - (isNormallyClosed ? unit * 0.2 : 0)
                path.move(to: CGPoint(x: x0, y: bar))
                path.addLine(to: CGPoint(x: x1, y: bar))
                path.move(to: CGPoint(x: center, y: bar))
                path.addLine(to: CGPoint(x: center, y: top))
                path.move(to: CGPoint(x: center - unit * 0.25, y: top))
                path.addLine(to: CGPoint(x: center + unit * 0.25, y: top))
            }
            local.stroke(path, with: .color(color), style: style)

        case .capacitor:
            // Two plates with a gap between them.
            let gap = halfBody * 0.22
            let plate = unit * 0.75
            var path = Path()
            path.move(to: CGPoint(x: center - halfBody, y: 0))
            path.addLine(to: CGPoint(x: center - gap, y: 0))
            path.move(to: CGPoint(x: center + gap, y: 0))
            path.addLine(to: CGPoint(x: center + halfBody, y: 0))
            for x in [center - gap, center + gap] {
                path.move(to: CGPoint(x: x, y: -plate))
                path.addLine(to: CGPoint(x: x, y: plate))
            }
            local.stroke(path, with: .color(color), style: style)

        case .inductor:
            // Four half loops on one side of the line.
            let loops = 4
            let radius = halfBody / CGFloat(loops)
            var path = Path()
            path.move(to: CGPoint(x: center - halfBody, y: 0))
            for loop in 0..<loops {
                let middle = center - halfBody + radius * CGFloat(2 * loop + 1)
                for step in 1...12 {
                    let angle = CGFloat.pi * (1 - CGFloat(step) / 12)
                    path.addLine(to: CGPoint(x: middle + radius * cos(angle), y: -radius * sin(angle)))
                }
            }
            local.stroke(path, with: .color(color), style: style)

        case .signalGenerator:
            // A circle with a sine wave, and + towards the end terminal.
            // The wave and signs are drawn upright, in the unrotated context.
            local.stroke(
                Path(ellipseIn: CGRect(x: center - halfBody, y: -halfBody, width: halfBody * 2, height: halfBody * 2)),
                with: .color(color), style: style
            )
            let direction = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
            func along(_ distance: CGFloat) -> CGPoint {
                CGPoint(x: a.x + direction.x * distance, y: a.y + direction.y * distance)
            }
            let middle = along(center)
            // Narrower when lying down, so the wave keeps clear of the signs.
            let width = halfBody * (abs(direction.x) > abs(direction.y) ? 0.3 : 0.45), height = halfBody * 0.25
            // The waveform, one period across the middle (shared with the web version).
            let points = SymbolPainter.wavePoints(waveform).map { CGPoint(x: middle.x + width * $0.x, y: middle.y + height * $0.y) }
            var wave = Path()
            wave.addLines(points)
            context.stroke(wave, with: .color(color), style: style)
            let sign = halfBody * 0.14
            let plus = along(center + halfBody * 0.68)
            let minus = along(center - halfBody * 0.68)
            var signs = Path()
            signs.move(to: CGPoint(x: plus.x - sign, y: plus.y))
            signs.addLine(to: CGPoint(x: plus.x + sign, y: plus.y))
            signs.move(to: CGPoint(x: plus.x, y: plus.y - sign))
            signs.addLine(to: CGPoint(x: plus.x, y: plus.y + sign))
            signs.move(to: CGPoint(x: minus.x - sign, y: minus.y))
            signs.addLine(to: CGPoint(x: minus.x + sign, y: minus.y))
            context.stroke(signs, with: .color(color), style: StrokeStyle(lineWidth: max(1, lineWidth * 0.8), lineCap: .round))

        case .voltageSource, .currentSource, .vcvs, .ccvs, .vccs, .cccs:
            // Independent sources are circles, controlled sources diamonds.
            let outline: Path
            if kind.isDependent {
                var diamond = Path()
                diamond.move(to: CGPoint(x: center - halfBody, y: 0))
                diamond.addLine(to: CGPoint(x: center, y: -halfBody))
                diamond.addLine(to: CGPoint(x: center + halfBody, y: 0))
                diamond.addLine(to: CGPoint(x: center, y: halfBody))
                diamond.closeSubpath()
                outline = diamond
            } else {
                outline = Path(ellipseIn: CGRect(x: center - halfBody, y: -halfBody, width: halfBody * 2, height: halfBody * 2))
            }
            local.stroke(outline, with: .color(color), style: style)

            if kind.setsVoltage {
                // "+" towards the end terminal, "−" towards the start terminal.
                // Drawn in the unrotated context so the "−" always stays horizontal.
                let sign = halfBody * (kind.isDependent ? 0.22 : 0.28)
                let offset = halfBody * (kind.isDependent ? 0.42 : 0.48)
                let direction = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
                func along(_ distance: CGFloat) -> CGPoint {
                    CGPoint(x: a.x + direction.x * distance, y: a.y + direction.y * distance)
                }
                let plus = along(center + offset)
                let minus = along(center - offset)
                var signs = Path()
                signs.move(to: CGPoint(x: plus.x - sign, y: plus.y))
                signs.addLine(to: CGPoint(x: plus.x + sign, y: plus.y))
                signs.move(to: CGPoint(x: plus.x, y: plus.y - sign))
                signs.addLine(to: CGPoint(x: plus.x, y: plus.y + sign))
                signs.move(to: CGPoint(x: minus.x - sign, y: minus.y))
                signs.addLine(to: CGPoint(x: minus.x + sign, y: minus.y))
                context.stroke(signs, with: .color(color), style: style)
            } else {
                // Arrow pointing towards the end terminal (direction of current).
                let reach = kind.isDependent ? 0.5 : 0.6
                let tail = center - halfBody * reach
                let tip = center + halfBody * reach
                let head = halfBody * 0.3
                var arrow = Path()
                arrow.move(to: CGPoint(x: tail, y: 0))
                arrow.addLine(to: CGPoint(x: tip, y: 0))
                arrow.move(to: CGPoint(x: tip - head, y: -head * 0.8))
                arrow.addLine(to: CGPoint(x: tip, y: 0))
                arrow.addLine(to: CGPoint(x: tip - head, y: head * 0.8))
                local.stroke(arrow, with: .color(color), style: style)
            }
        }
    }

    /// The color of a lit LED.
    static let litColor = Color(red: 1, green: 0.72, blue: 0)
    /// Warnings on the sheet, e.g. an LED with too much current.
    static let warningColor = Color(red: 0.85, green: 0.2, blue: 0.05)

    /// The light of a lit LED of a color.
    static func light(_ color: LEDColor) -> Color {
        Color(red: color.light.r, green: color.light.g, blue: color.light.b)
    }

    /// Draws a filled arrowhead centered on `point`, pointing along `direction` (a unit vector).
    static func drawCurrentArrowhead(at point: CGPoint, direction: CGPoint, size: CGFloat, color: Color, in context: GraphicsContext) {
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let half = size / 2
        let tip = CGPoint(x: point.x + direction.x * half, y: point.y + direction.y * half)
        let base = CGPoint(x: point.x - direction.x * half, y: point.y - direction.y * half)
        let width = size * 0.38
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x + normal.x * width, y: base.y + normal.y * width))
        head.addLine(to: CGPoint(x: base.x - normal.x * width, y: base.y - normal.y * width))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    /// Draws a mesh current: a curved arrow most of the way round `center`,
    /// from the bottom over the top to the right side, like one drawn by hand.
    static func drawMeshArrow(
        at center: CGPoint, radius: CGFloat, clockwise: Bool, color: Color, lineWidth: CGFloat, in context: GraphicsContext
    ) {
        // Angles in screen coordinates (y down), so growing angles turn clockwise.
        let start = clockwise ? 100.0 : 80.0
        let end = clockwise ? 350.0 : -170.0
        var path = Path()
        let steps = 40
        for step in 0...steps {
            let angle = (start + (end - start) * Double(step) / Double(steps)) * .pi / 180
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        let last = end * .pi / 180
        let tip = CGPoint(x: center.x + radius * cos(last), y: center.y + radius * sin(last))
        let sign: Double = clockwise ? 1 : -1
        let direction = CGPoint(x: -sin(last) * sign, y: cos(last) * sign)
        drawCurrentArrowhead(at: tip, direction: direction, size: max(6, radius * 0.45), color: color, in: context)
    }

    /// Draws a ground (0 V) symbol: a short stem from the connection point and
    /// three bars getting narrower, pointing along `direction` (a unit vector).
    static func drawGround(at point: CGPoint, direction: CGPoint, unit: CGFloat, color: Color, lineWidth: CGFloat, in context: GraphicsContext) {
        let normal = CGPoint(x: -direction.y, y: direction.x)
        func offset(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(
                x: point.x + direction.x * along * unit + normal.x * across * unit,
                y: point.y + direction.y * along * unit + normal.y * across * unit
            )
        }
        var path = Path()
        path.move(to: point)
        path.addLine(to: offset(0.7, 0))
        for (along, halfWidth) in [(0.7, 0.6), (0.95, 0.38), (1.2, 0.16)] as [(CGFloat, CGFloat)] {
            path.move(to: offset(along, -halfWidth))
            path.addLine(to: offset(along, halfWidth))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    /// Draws a voltage point: a large dot on the node. Clearly bigger than a
    /// junction dot so the two aren't confused.
    static func drawProbe(at point: CGPoint, unit: CGFloat, color: Color, in context: GraphicsContext) {
        let radius = max(4, unit * 0.38)
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
            with: .color(color)
        )
    }
}

/// A small icon of a tool, drawn with the same code as the schematic.
struct ToolIcon: View {
    let tool: Tool
    var color: Color = .primary

    @AppStorage(SettingsKey.resistorStyle) private var resistorStyle = ResistorStyle.iec

    var body: some View {
        Canvas { context, size in
            let a = CGPoint(x: 2, y: size.height / 2)
            let b = CGPoint(x: size.width - 2, y: size.height / 2)
            let unit = size.width / 4.5
            switch tool {
            case .gate, .invert:
                // Logic symbols come from the shared drawing code.
                ScenePrimitiveRenderer.draw(
                    ToolIconScene.primitives(for: .tool(tool), color: SceneColor(white: 0), resistorStyle: .iec),
                    in: context, tint: color
                )
            case .select:
                var image = context.resolve(Image(systemName: "cursorarrow"))
                image.shading = .color(color)
                context.draw(image, at: CGPoint(x: size.width / 2, y: size.height / 2))
            case .wire:
                var path = Path()
                path.move(to: CGPoint(x: 3, y: size.height - 5))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height - 5))
                path.addLine(to: CGPoint(x: size.width / 2, y: 5))
                path.addLine(to: CGPoint(x: size.width - 3, y: 5))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            case .component(let kind):
                SymbolRenderer.drawComponent(
                    kind, from: a, to: b, unit: unit, color: color, lineWidth: 1.5,
                    resistorStyle: resistorStyle, in: context
                )
            case .ground:
                SymbolRenderer.drawGround(
                    at: CGPoint(x: size.width / 2, y: 3),
                    direction: CGPoint(x: 0, y: 1),
                    unit: 14,
                    color: color,
                    lineWidth: 1.5,
                    in: context
                )
            case .current:
                var line = Path()
                line.move(to: a)
                line.addLine(to: b)
                context.stroke(line, with: .color(color), lineWidth: 1.5)
                SymbolRenderer.drawCurrentArrowhead(
                    at: CGPoint(x: size.width / 2, y: size.height / 2),
                    direction: CGPoint(x: 1, y: 0),
                    size: 11,
                    color: color,
                    in: context
                )
            case .probe:
                let dot = CGPoint(x: size.width * 0.28, y: size.height * 0.62)
                var line = Path()
                line.move(to: CGPoint(x: 1, y: dot.y))
                line.addLine(to: CGPoint(x: size.width * 0.55, y: dot.y))
                context.stroke(line, with: .color(color), lineWidth: 1.5)
                SymbolRenderer.drawProbe(at: dot, unit: 12, color: color, in: context)
                context.draw(
                    Text("V").font(.system(size: 11, weight: .semibold)).foregroundStyle(color),
                    at: CGPoint(x: size.width * 0.62, y: size.height * 0.45),
                    anchor: .leading
                )
                        case .equivalent:
                // A small resistor with "eq" beneath it.
                SymbolRenderer.drawComponent(
                    .resistor, from: CGPoint(x: 2, y: 8), to: CGPoint(x: size.width - 2, y: 8),
                    unit: size.width / 5, color: color, lineWidth: 1.5, resistorStyle: resistorStyle, in: context
                )
                context.draw(
                    Text("eq").font(.system(size: 10, weight: .semibold)).foregroundStyle(color),
                    at: CGPoint(x: size.width / 2, y: size.height - 1),
                    anchor: .bottom
                )
            case .power:
                // A circle with "P" in it.
                let circle = CGRect(x: size.width / 2 - 10, y: size.height / 2 - 10, width: 20, height: 20)
                context.stroke(Path(ellipseIn: circle), with: .color(color), lineWidth: 1.5)
                context.draw(
                    Text("P").font(.system(size: 11, weight: .semibold)).foregroundStyle(color),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )
            case .mesh:
                SymbolRenderer.drawMeshArrow(
                    at: CGPoint(x: size.width / 2, y: size.height / 2), radius: size.height * 0.36,
                    clockwise: true, color: color, lineWidth: 1.5, in: context
                )
                context.draw(
                    Text("I").font(.system(size: 9, weight: .semibold)).foregroundStyle(color),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )
            case .groupArea:
                // A tinted box with a name tab in its corner.
                let box = CGRect(x: 3, y: 3, width: size.width - 6, height: size.height - 6)
                context.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(color.opacity(0.15)))
                context.stroke(Path(roundedRect: box, cornerRadius: 2), with: .color(color), lineWidth: 1.2)
                context.fill(Path(CGRect(x: box.minX, y: box.minY, width: box.width * 0.45, height: 4)), with: .color(color))
            case .text:
                var image = context.resolve(Image(systemName: "character.textbox"))
                image.shading = .color(color)
                context.draw(image, at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
        }
        .frame(width: 30, height: 24)
        .foregroundStyle(color)
    }
}

#Preview("Symboler") {
    Canvas { context, size in
        let unit: CGFloat = 20
        let color = Color(red: 0.62, green: 0.1, blue: 0.12)
        SymbolRenderer.drawComponent(.resistor, from: CGPoint(x: 20, y: 40), to: CGPoint(x: 100, y: 40), unit: unit, color: color, lineWidth: 2, resistorStyle: .iec, in: context)
        SymbolRenderer.drawComponent(.resistor, from: CGPoint(x: 20, y: 100), to: CGPoint(x: 100, y: 100), unit: unit, color: color, lineWidth: 2, resistorStyle: .ansi, in: context)
        SymbolRenderer.drawComponent(.resistor, from: CGPoint(x: 140, y: 20), to: CGPoint(x: 140, y: 100), unit: unit, color: color, lineWidth: 2, resistorStyle: .ansi, in: context)
        SymbolRenderer.drawGround(at: CGPoint(x: 200, y: 40), direction: CGPoint(x: 0, y: 1), unit: unit, color: color, lineWidth: 2, in: context)
        for (index, kind) in ComponentKind.dependentSources.enumerated() {
            let x = 20 + CGFloat(index) * 75
            SymbolRenderer.drawComponent(kind, from: CGPoint(x: x, y: 190), to: CGPoint(x: x, y: 130), unit: unit, color: color, lineWidth: 2, in: context)
        }
        SymbolRenderer.drawGround(at: CGPoint(x: 260, y: 60), direction: CGPoint(x: 1, y: 0), unit: unit, color: color, lineWidth: 2, in: context)
        for (index, kind) in [ComponentKind.capacitor, .inductor, .signalGenerator].enumerated() {
            let x = 20 + CGFloat(index) * 100
            SymbolRenderer.drawComponent(kind, from: CGPoint(x: x, y: 240), to: CGPoint(x: x + 80, y: 240), unit: unit, color: color, lineWidth: 2, in: context)
            SymbolRenderer.drawComponent(kind, from: CGPoint(x: x + 40, y: 340), to: CGPoint(x: x + 40, y: 270), unit: unit, color: color, lineWidth: 2, in: context)
        }
        for (index, closed) in [false, true].enumerated() {
            let y = 380 + CGFloat(index) * 50
            SymbolRenderer.drawComponent(.toggleSwitch, from: CGPoint(x: 20, y: y), to: CGPoint(x: 100, y: y), unit: unit, color: color, lineWidth: 2, isClosed: closed, in: context)
            SymbolRenderer.drawComponent(.pushButton, from: CGPoint(x: 140, y: y), to: CGPoint(x: 220, y: y), unit: unit, color: color, lineWidth: 2, isClosed: closed, in: context)
            SymbolRenderer.drawComponent(.pushButton, from: CGPoint(x: 240, y: y), to: CGPoint(x: 310, y: y), unit: unit, color: color, lineWidth: 2, isClosed: !closed, isNormallyClosed: true, in: context)
        }
        SymbolRenderer.drawComponent(.signalGenerator, from: CGPoint(x: 180, y: 110), to: CGPoint(x: 260, y: 110), unit: unit, color: color, lineWidth: 2, waveform: .square, in: context)
    }
    .frame(width: 320, height: 460)
    .background(Color(red: 0.957, green: 0.953, blue: 0.937))
}
