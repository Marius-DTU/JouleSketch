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
        isLit: Bool = false,
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
            if isLit { local.fill(triangle, with: .color(litColor.opacity(0.45))) }
            local.stroke(triangle, with: .color(color), style: style)

            var bar = Path()
            bar.move(to: CGPoint(x: tip, y: -size))
            bar.addLine(to: CGPoint(x: tip, y: size))
            local.stroke(bar, with: .color(color), style: style)

            if kind == .led {
                // Two arrows for the emitted light, bright when the LED is on.
                let arrowColor = isLit ? litColor : color
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
    }
    .frame(width: 320, height: 210)
    .background(Color(red: 0.957, green: 0.953, blue: 0.937))
}
