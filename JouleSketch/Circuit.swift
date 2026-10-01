import CoreGraphics
import Foundation

/// A point on the snapping grid, in whole grid units.
nonisolated struct GridPoint: Hashable, Codable {
    var x: Int
    var y: Int

    static func + (lhs: GridPoint, rhs: GridPoint) -> GridPoint {
        GridPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: GridPoint, rhs: GridPoint) -> GridPoint {
        GridPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    /// Rotates the point 90° clockwise (on screen, where y points down) around `pivot`.
    func rotatedClockwise(around pivot: GridPoint) -> GridPoint {
        let relative = self - pivot
        return pivot + GridPoint(x: -relative.y, y: relative.x)
    }
}

/// The kinds of two-terminal components that can be placed on the schematic.
/// New kinds (capacitor, inductor, …) are added here and in `SymbolRenderer`.
nonisolated enum ComponentKind: String, Codable, CaseIterable, Identifiable {
    case resistor
    case voltageSource
    case currentSource
    /// Voltage-controlled voltage source: V = μ·Vs.
    case vcvs
    /// Current-controlled voltage source: V = r·Is.
    case ccvs
    /// Voltage-controlled current source: I = g·Vs.
    case vccs
    /// Current-controlled current source: I = β·Is.
    case cccs
    /// A diode from anode (start) to cathode (end). Its value is the forward
    /// voltage: when it conducts, the voltage across it is exactly that;
    /// otherwise no current flows.
    case diode
    /// A light-emitting diode, calculated like a diode.
    case led

    var id: String { rawValue }

    /// The controlled (dependent) sources, drawn as diamonds.
    static let dependentSources: [ComponentKind] = [.vcvs, .ccvs, .vccs, .cccs]

    var displayName: String {
        switch self {
        case .resistor: "Modstand"
        case .voltageSource: "Spændingskilde"
        case .currentSource: "Strømkilde"
        case .vcvs: "Spændingsstyret spændingskilde"
        case .ccvs: "Strømstyret spændingskilde"
        case .vccs: "Spændingsstyret strømkilde"
        case .cccs: "Strømstyret strømkilde"
        case .diode: "Diode"
        case .led: "Lysdiode (LED)"
        }
    }

    /// Prefix used for automatic naming (R1, S1, D1, …). All sources share
    /// "S" (supply), so they're numbered together, and so do both diodes.
    var namePrefix: String {
        switch self {
        case .resistor: "R"
        case .diode, .led: "D"
        default: "S"
        }
    }

    /// The value a newly placed component starts with: a typical forward
    /// voltage for diodes, unknown for everything else.
    var defaultValue: Double? {
        switch self {
        case .diode: 0.7
        case .led: 2
        default: nil
        }
    }

    /// The unit of the component's value. For controlled sources the value is
    /// the gain: μ (V/V), r (V/A = Ω), g (A/V = S) or β (A/A).
    var unit: String {
        switch self {
        case .resistor: "Ω"
        case .voltageSource: "V"
        case .currentSource: "A"
        case .vcvs: "V/V"
        case .ccvs: "Ω"
        case .vccs: "S"
        case .cccs: "A/A"
        case .diode, .led: "V"
        }
    }

    /// The symbol of a controlled source's gain.
    var gainSymbol: String {
        switch self {
        case .vcvs: "μ"
        case .ccvs: "r"
        case .vccs: "g"
        case .cccs: "β"
        default: ""
        }
    }

    var isDependent: Bool { Self.dependentSources.contains(self) }
    /// Sources that set a voltage (their current follows from the circuit).
    var setsVoltage: Bool { self == .voltageSource || self == .vcvs || self == .ccvs }
    /// Sources that set a current (their voltage follows from the circuit).
    var setsCurrent: Bool { self == .currentSource || self == .vccs || self == .cccs }
    var isVoltageControlled: Bool { self == .vcvs || self == .vccs }
    var isCurrentControlled: Bool { self == .ccvs || self == .cccs }
    var isDiode: Bool { self == .diode || self == .led }

    /// The label of the value field, or `nil` for the plain "Værdi (unit)".
    /// The unit shown with the value. Gains are written as ratios, A/V
    /// rather than S and V/A rather than Ω (the same in formulas), so they
    /// read as what they convert.
    var displayUnit: String {
        switch self {
        case .vccs: "A/V"
        case .ccvs: "V/A"
        default: unit
        }
    }

    var valueTitle: String? {
        if isDependent { return displayUnit.isEmpty ? "Faktor \(gainSymbol)" : "Faktor \(gainSymbol) (\(displayUnit))" }
        if isDiode { return "Tærskelspænding (V)" }
        return nil
    }

    /// Resistances and forward voltages can't be negative.
    var allowsNegativeValue: Bool { self != .resistor && !isDiode }
}

/// A two-terminal component spanning from `start` to `end`.
/// The two points are always on a horizontal or vertical line.
/// For sources, the direction matters: a voltage source has its `+`
/// terminal at `end`, and a current source pushes current towards `end`.
nonisolated struct CircuitComponent: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: ComponentKind
    var start: GridPoint
    var end: GridPoint
    var name: String
    /// The value in base SI units (Ω, V or A), or the gain of a controlled
    /// source. `nil` means unknown.
    var value: Double?
    /// Free-form note written by the user.
    var note = ""
    /// How far a voltage-controlled source's "Vs" label sits from the middle
    /// between its + and − sense points (grid units): sideways when the points
    /// are above each other, up or down when they're side by side.
    var senseLabelOffsetX = -1.5
    var senseLabelOffsetY = -1.5
    /// A controlled source's own name for what controls it; `nil` for the
    /// default "Vs" or "Is".
    var controlName: String?
    /// Whether a circle around the component shows the power it absorbs.
    /// Optional so files saved before power circles existed still open.
    var showsPower: Bool?

    var isPowerShown: Bool { showsPower == true }

    /// The name of the power absorbed, e.g. "P_{R1}".
    var powerName: String {
        let base = name.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "").replacingOccurrences(of: "_", with: "")
        return "P_{\(base)}"
    }

    /// The name of the controlling quantity: `controlName`, or "Vs" / "Is".
    var controlLabel: String {
        if let controlName, !controlName.trimmingCharacters(in: .whitespaces).isEmpty { return controlName }
        return kind.isVoltageControlled ? "Vs" : "Is"
    }
}

/// A sense marker belonging to a controlled source: the + or − point that a
/// voltage-controlled source measures Vs between, or the point on a wire
/// where a current-controlled source measures Is.
nonisolated struct SenseMarker: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case plus, minus, current
    }

    var id = UUID()
    /// The controlled source the marker belongs to.
    var ownerID: UUID
    var kind: Kind
    /// Position in grid units. Voltage points sit on grid points; the current
    /// marker measures the current in the wire it's placed on.
    var x: Double
    var y: Double
    /// Reverses the measured current direction (current markers only).
    var flipped = false

    var point: CGPoint {
        get { CGPoint(x: x, y: y) }
        set {
            x = newValue.x
            y = newValue.y
        }
    }

    var gridPoint: GridPoint { GridPoint(x: Int(x.rounded()), y: Int(y.rounded())) }
}

/// A wire made of one or more horizontal/vertical segments through `points`.
/// The first and last points are the wire's ends; the points in between are
/// support points (bends).
nonisolated struct Wire: Identifiable, Codable, Hashable {
    var id = UUID()
    var points: [GridPoint]

    var start: GridPoint { points.first ?? GridPoint(x: 0, y: 0) }
    var end: GridPoint { points.last ?? GridPoint(x: 0, y: 0) }

    var segments: [(GridPoint, GridPoint)] {
        Array(zip(points, points.dropFirst()))
    }

    /// The index of the segment that contains both `a` and `b`, if any.
    func segmentIndex(containing a: GridPoint, _ b: GridPoint) -> Int? {
        segments.firstIndex { segment in
            [a, b].allSatisfy { $0 == segment.0 || $0 == segment.1 || Circuit.point($0, isInteriorOf: segment.0, segment.1) }
        }
    }

    /// The point on the wire nearest to `point` (in grid units), together with
    /// the unit direction of that segment in the order of the wire's points.
    func nearest(to point: CGPoint) -> (point: CGPoint, direction: CGPoint, distance: CGFloat)? {
        nearestOnSegments(to: point).map { ($0.point, $0.direction, $0.distance) }
    }

    /// Like `nearest(to:)`, also returning the segment index and the relative
    /// position `fraction` (0…1) along that segment. Only segments passing
    /// `filter` are considered.
    func nearestOnSegments(
        to point: CGPoint,
        where filter: (GridPoint, GridPoint) -> Bool = { _, _ in true }
    ) -> (point: CGPoint, direction: CGPoint, distance: CGFloat, segment: Int, fraction: CGFloat)? {
        var best: (point: CGPoint, direction: CGPoint, distance: CGFloat, segment: Int, fraction: CGFloat)?
        for (index, (a, b)) in segments.enumerated() where filter(a, b) {
            let pa = CGPoint(x: a.x, y: a.y)
            let pb = CGPoint(x: b.x, y: b.y)
            let length = pa.distance(to: pb)
            guard length > 0 else { continue }
            let direction = CGPoint(x: (pb.x - pa.x) / length, y: (pb.y - pa.y) / length)
            let t = max(0, min(length, (point.x - pa.x) * direction.x + (point.y - pa.y) * direction.y))
            let candidate = CGPoint(x: pa.x + direction.x * t, y: pa.y + direction.y * t)
            let distance = candidate.distance(to: point)
            if distance < (best?.distance ?? .infinity) {
                best = (candidate, direction, distance, index, t / length)
            }
        }
        return best
    }

    /// Whether the wire runs through `point` somewhere other than its two ends.
    func passesThrough(_ point: GridPoint) -> Bool {
        guard point != start, point != end else { return false }
        return points.contains(point) || segments.contains { Circuit.point(point, isInteriorOf: $0.0, $0.1) }
    }
}

/// A named current flowing in a wire, drawn as an arrow on the wire.
/// The arrow stays on its wire: it is drawn at the point of the wire
/// nearest to `anchor`, so it follows along when the wire changes shape.
nonisolated struct CurrentArrow: Identifiable, Codable, Hashable {
    var id = UUID()
    var wireID: UUID
    /// Preferred position in grid units.
    var anchorX: Double
    var anchorY: Double
    /// `true` when the current flows in the order of the wire's points.
    var forward: Bool
    var name: String
    /// The current in amperes. `nil` means unknown.
    var value: Double?
    /// Free-form note written by the user.
    var note = ""

    var anchor: CGPoint {
        get { CGPoint(x: anchorX, y: anchorY) }
        set {
            anchorX = newValue.x
            anchorY = newValue.y
        }
    }
}

/// A ground reference: the node it's connected to is 0 V.
nonisolated struct Ground: Identifiable, Codable, Hashable {
    var id = UUID()
    /// The connection point.
    var position: GridPoint
    /// Quarter turns clockwise; 0 means the symbol hangs below the connection point.
    var rotation = 0

    /// Unit step from the connection point towards the symbol.
    var direction: GridPoint {
        switch rotation % 4 {
        case 0: GridPoint(x: 0, y: 1)
        case 1: GridPoint(x: -1, y: 0)
        case 2: GridPoint(x: 0, y: -1)
        default: GridPoint(x: 1, y: 0)
        }
    }
}

/// A named voltage point (node voltage) placed on a node of the circuit.
/// With a `negative` point it measures the voltage drop between two points
/// instead (V_A = V(+) − V(−)), drawn like a controlled source's Vs markers.
nonisolated struct Probe: Identifiable, Codable, Hashable {
    var id = UUID()
    /// The voltage point, or the + point of a voltage drop.
    var position: GridPoint
    var name: String
    /// The node voltage in volts, or the voltage drop. `nil` means unknown.
    var value: Double?
    /// Free-form note written by the user.
    var note = ""
    /// The − point of a voltage drop; `nil` for a plain voltage point.
    var negative: GridPoint?
    /// How far a voltage drop's label sits out from the middle between its
    /// points (grid units); `nil` for the default.
    var labelOffset: Double?

    var isVoltageDrop: Bool { negative != nil }
    var labelDistance: Double { labelOffset ?? -1.5 }
}

/// The equivalent resistance (Req) seen between two points of the circuit,
/// drawn as a grey resistor from `start` to `end`. The resistors it's made of
/// are drawn in its color. It doesn't take part in the calculation.
nonisolated struct EquivalentResistance: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Index into the palette of Req colors.
    var colorIndex: Int
    var start: GridPoint
    var end: GridPoint
}

/// A text box on the sheet for notes and calculations. Each line is either
/// plain text or a LaTeX formula (math mode).
nonisolated struct TextBox: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Top-left corner.
    var position: GridPoint
    var lines: [TextLine] = [TextLine()]

    var isEmpty: Bool { lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
}

nonisolated struct TextLine: Identifiable, Codable, Hashable {
    var id = UUID()
    var text = ""
    /// `true` for a LaTeX formula, `false` for plain text.
    var isMath = false
}

/// A box drawn around part of the sheet (⌘ + right-drag). What lies entirely
/// inside it is left out of the automatic calculation and the Maple output.
nonisolated struct ExcludedArea: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Opposite corners, top left and bottom right.
    var from: GridPoint
    var to: GridPoint

    init(corner a: GridPoint, corner b: GridPoint) {
        from = GridPoint(x: min(a.x, b.x), y: min(a.y, b.y))
        to = GridPoint(x: max(a.x, b.x), y: max(a.y, b.y))
    }

    func contains(_ point: GridPoint) -> Bool {
        (from.x...to.x).contains(point.x) && (from.y...to.y).contains(point.y)
    }

    func contains(_ point: CGPoint) -> Bool {
        (Double(from.x)...Double(to.x)).contains(point.x) && (Double(from.y)...Double(to.y)).contains(point.y)
    }
}

/// A named box around part of the sheet, with a lightly tinted background
/// and its name in the top-left corner. The Maple window can show the
/// output and walkthrough for just what lies inside one group.
nonisolated struct GroupArea: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Opposite corners, top left and bottom right.
    var from: GridPoint
    var to: GridPoint
    /// The tint, as RGB from 0 to 1.
    var red: Double
    var green: Double
    var blue: Double

    /// Tints for new groups, taken in turn.
    static let palette: [(Double, Double, Double)] = [
        (0.25, 0.52, 0.96), (0.20, 0.70, 0.40), (0.96, 0.58, 0.16),
        (0.62, 0.38, 0.90), (0.90, 0.30, 0.34), (0.12, 0.68, 0.74),
    ]

    init(corner a: GridPoint, corner b: GridPoint, name: String, colorIndex: Int) {
        from = GridPoint(x: min(a.x, b.x), y: min(a.y, b.y))
        to = GridPoint(x: max(a.x, b.x), y: max(a.y, b.y))
        self.name = name
        (red, green, blue) = Self.palette[colorIndex % Self.palette.count]
    }

    func contains(_ point: GridPoint) -> Bool {
        (from.x...to.x).contains(point.x) && (from.y...to.y).contains(point.y)
    }

    func contains(_ point: CGPoint) -> Bool {
        (Double(from.x)...Double(to.x)).contains(point.x) && (Double(from.y)...Double(to.y)).contains(point.y)
    }

    /// Where a resize handle sits, in grid units.
    func position(of handle: Handle) -> CGPoint {
        func coordinate(_ side: Int, _ low: Int, _ high: Int) -> CGFloat {
            side < 0 ? CGFloat(low) : side > 0 ? CGFloat(high) : CGFloat(low + high) / 2
        }
        return CGPoint(x: coordinate(handle.x, from.x, to.x), y: coordinate(handle.y, from.y, to.y))
    }

    /// A resize handle: a corner or the middle of a side. −1 is the left or
    /// top edge, 1 the right or bottom edge, 0 the middle.
    struct Handle: Hashable {
        let x: Int
        let y: Int

        static let all: [Handle] = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]
            .map { Handle(x: $0.0, y: $0.1) }
    }
}

/// A mesh current drawn as a curved arrow inside a mesh, with its name in the
/// middle. The mesh method uses its name and direction for that mesh.
nonisolated struct MeshMarker: Identifiable, Codable, Hashable {
    var id = UUID()
    /// The middle of the arrow.
    var position: GridPoint
    var name: String
    var clockwise = true
}

/// A freehand line drawn on the page with the pencil.
nonisolated struct Stroke: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Points in grid units, in drawing order.
    var xs: [Double]
    var ys: [Double]
    /// Index into the pen colors (`Stroke.colorCount`).
    var color = 0
    /// Index into `Stroke.widths`.
    var size = 1

    /// Line widths of the pen sizes, in points at 100 % zoom.
    static let widths: [CGFloat] = [1, 2, 3.5, 5.5, 9]
    static let colorCount = 5

    init(points: [CGPoint], color: Int = 0, size: Int = 1) {
        xs = points.map { Double($0.x) }
        ys = points.map { Double($0.y) }
        self.color = color
        self.size = size
    }

    /// Strokes drawn before colors and sizes existed get the default pen.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        xs = try container.decode([Double].self, forKey: .xs)
        ys = try container.decode([Double].self, forKey: .ys)
        color = try container.decodeIfPresent(Int.self, forKey: .color) ?? 0
        size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 1
    }

    var width: CGFloat { Stroke.widths[min(max(size, 0), Stroke.widths.count - 1)] }

    /// What's left of the stroke after erasing a circle (grid units): the
    /// parts outside it, each as a stroke of its own. The first keeps the id.
    /// Whether the eraser circle touches the stroke anywhere.
    func touches(_ center: CGPoint, radius: CGFloat) -> Bool {
        touches(from: center, to: center, radius: radius)
    }

    /// Whether an eraser moving in a straight line from `start` to `end`
    /// touches the stroke. Works straight on the stored numbers, since it
    /// runs for every stroke on every eraser movement.
    func touches(from start: CGPoint, to end: CGPoint, radius: CGFloat) -> Bool {
        guard !xs.isEmpty else { return false }
        // The box around the eraser's way; pieces outside it are skipped cheaply.
        let minX = min(start.x, end.x) - radius, maxX = max(start.x, end.x) + radius
        let minY = min(start.y, end.y) - radius, maxY = max(start.y, end.y) + radius
        var previous = CGPoint(x: xs[0], y: ys[0])
        if previous.distance(toSegment: start, end) <= radius { return true }
        for index in 1..<xs.count {
            let point = CGPoint(x: xs[index], y: ys[index])
            defer { previous = point }
            if max(previous.x, point.x) < minX || min(previous.x, point.x) > maxX
                || max(previous.y, point.y) < minY || min(previous.y, point.y) > maxY {
                continue
            }
            if Self.segmentDistance(previous, point, start, end) <= radius { return true }
        }
        return false
    }

    /// The shortest distance between the segments a–b and c–d.
    private static func segmentDistance(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat {
        func cross(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> CGFloat {
            (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x)
        }
        // Crossing segments touch.
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        if (d1 > 0) != (d2 > 0), (d3 > 0) != (d4 > 0), d1 != 0, d2 != 0, d3 != 0, d4 != 0 { return 0 }
        return min(a.distance(toSegment: c, d), b.distance(toSegment: c, d),
                   c.distance(toSegment: a, b), d.distance(toSegment: a, b))
    }

    func erasing(around center: CGPoint, radius: CGFloat) -> [Stroke] {
        let original = self.points
        guard zip(original, original.dropFirst()).contains(where: { center.distance(toSegment: $0, $1) <= radius })
                || original.contains(where: { $0.distance(to: center) <= radius })
        else { return [self] }

        // Extra points along long pieces under the eraser, so it only takes
        // what it covers. Pieces elsewhere are left as they are.
        let step = max(radius / 3, 0.01)
        var points: [CGPoint] = original.prefix(1).map { $0 }
        for (a, b) in zip(original, original.dropFirst()) {
            let count = Int(a.distance(to: b) / step)
            if count > 1, center.distance(toSegment: a, b) <= radius {
                for i in 1..<count {
                    let t = CGFloat(i) / CGFloat(count)
                    points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                }
            }
            points.append(b)
        }
        func isErased(_ p: CGPoint) -> Bool { p.distance(to: center) <= radius }

        var pieces: [[CGPoint]] = [[]]
        for (index, point) in points.enumerated() {
            if isErased(point) {
                pieces.append([])
            } else if index > 0, !pieces[pieces.count - 1].isEmpty,
                      center.distance(toSegment: points[index - 1], point) <= radius {
                // The eraser crosses the line between two points outside it.
                pieces.append([point])
            } else {
                pieces[pieces.count - 1].append(point)
            }
        }
        return pieces.filter { $0.count >= 2 }.enumerated().map { index, piece in
            var stroke = Stroke(points: piece, color: color, size: size)
            if index == 0 { stroke.id = id }
            return stroke
        }
    }

    var points: [CGPoint] { zip(xs, ys).map { CGPoint(x: CGFloat($0), y: CGFloat($1)) } }
}

/// The complete schematic document.
nonisolated struct Circuit: Codable, Hashable {
    var components: [CircuitComponent] = []
    var wires: [Wire] = []
    var probes: [Probe] = []
    var currents: [CurrentArrow] = []
    var grounds: [Ground] = []
    var senses: [SenseMarker] = []
    var equivalents: [EquivalentResistance] = []
    var textBoxes: [TextBox] = []
    /// Components, voltage points and currents whose value was given by a
    /// "!name := …" line in a text box rather than typed in.
    var inheritedValues: Set<UUID> = []
    /// Freehand drawing on the page.
    var strokes: [Stroke] = []
    /// Parts of the sheet left out of the calculation.
    var excludedAreas: [ExcludedArea] = []
    /// Mesh currents marked for the mesh method.
    var meshMarkers: [MeshMarker] = []
    /// Named boxes dividing the sheet into groups for the Maple window.
    var groupAreas: [GroupArea] = []

    init() {}

    /// Missing lists decode as empty, so files saved before a kind of item
    /// existed (e.g. ground symbols) still open.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        components = try container.decodeIfPresent([CircuitComponent].self, forKey: .components) ?? []
        wires = try container.decodeIfPresent([Wire].self, forKey: .wires) ?? []
        probes = try container.decodeIfPresent([Probe].self, forKey: .probes) ?? []
        currents = try container.decodeIfPresent([CurrentArrow].self, forKey: .currents) ?? []
        grounds = try container.decodeIfPresent([Ground].self, forKey: .grounds) ?? []
        senses = try container.decodeIfPresent([SenseMarker].self, forKey: .senses) ?? []
        equivalents = try container.decodeIfPresent([EquivalentResistance].self, forKey: .equivalents) ?? []
        textBoxes = try container.decodeIfPresent([TextBox].self, forKey: .textBoxes) ?? []
        inheritedValues = try container.decodeIfPresent(Set<UUID>.self, forKey: .inheritedValues) ?? []
        strokes = try container.decodeIfPresent([Stroke].self, forKey: .strokes) ?? []
        excludedAreas = try container.decodeIfPresent([ExcludedArea].self, forKey: .excludedAreas) ?? []
        meshMarkers = try container.decodeIfPresent([MeshMarker].self, forKey: .meshMarkers) ?? []
        groupAreas = try container.decodeIfPresent([GroupArea].self, forKey: .groupAreas) ?? []
    }

    // MARK: Equivalent resistances

    /// The next free name: "Req", then "Req2", "Req3", …
    func nextEquivalentName() -> String {
        let used = Set(equivalents.map(\.name) + components.map(\.name))
        if !used.contains("Req") { return "Req" }
        var index = 2
        while used.contains("Req\(index)") { index += 1 }
        return "Req\(index)"
    }

    /// The first group color not used by another equivalent resistance.
    func nextEquivalentColorIndex() -> Int {
        let used = Set(equivalents.map(\.colorIndex))
        var index = 0
        while used.contains(index) { index += 1 }
        return index
    }

    // MARK: Sense markers of controlled sources

    func sense(of ownerID: UUID, _ kind: SenseMarker.Kind) -> SenseMarker? {
        senses.first { $0.ownerID == ownerID && $0.kind == kind }
    }

    /// A current marker as a current arrow on the wire it sits on, so it can be
    /// solved like one. `nil` if it isn't on a wire. The measured direction is
    /// right or down along the wire, reversed when the marker is flipped.
    func currentArrow(for marker: SenseMarker) -> CurrentArrow? {
        let candidates = wires.compactMap { wire in
            wire.nearest(to: marker.point).map { (wire: wire, nearest: $0) }
        }
        guard let hit = candidates.min(by: { $0.nearest.distance < $1.nearest.distance }),
              hit.nearest.distance < 0.3 else { return nil }
        let direction = hit.nearest.direction
        let pointsRightOrDown = direction.x + direction.y > 0
        return CurrentArrow(
            id: marker.id,
            wireID: hit.wire.id,
            anchorX: marker.x,
            anchorY: marker.y,
            forward: pointsRightOrDown != marker.flipped,
            name: components.first { $0.id == marker.ownerID }?.controlLabel ?? "Is",
            value: nil
        )
    }

    /// Where a current arrow is drawn (grid units) and which way it points.
    func placement(of arrow: CurrentArrow) -> (point: CGPoint, direction: CGPoint)? {
        guard let wire = wires.first(where: { $0.id == arrow.wireID }),
              let nearest = wire.nearest(to: arrow.anchor) else { return nil }
        let direction = arrow.forward
            ? nearest.direction
            : CGPoint(x: -nearest.direction.x, y: -nearest.direction.y)
        return (nearest.point, direction)
    }

    /// Keeps current arrows on the same stretch of a wire after its shape changed:
    /// each arrow stays at the same relative spot on the nearest segment
    /// with the same orientation as the one it sat on.
    mutating func retargetCurrents(onWire wireID: UUID, from old: Wire) {
        guard let new = wires.first(where: { $0.id == wireID }) else { return }
        for index in currents.indices where currents[index].wireID == wireID {
            let anchor = currents[index].anchor
            guard let location = old.nearestOnSegments(to: anchor) else { continue }
            let (oldA, oldB) = old.segments[location.segment]
            let isHorizontal = oldA.y == oldB.y
            guard let target = new.nearestOnSegments(to: anchor, where: { ($0.y == $1.y) == isHorizontal }) else { continue }

            let (a, b) = new.segments[target.segment]
            currents[index].anchorX = Double(a.x) + Double(b.x - a.x) * location.fraction
            currents[index].anchorY = Double(a.y) + Double(b.y - a.y) * location.fraction
            // Keep the arrow pointing the same way on screen.
            let oldDirection = location.direction
            if oldDirection.x * target.direction.x + oldDirection.y * target.direction.y < 0 {
                currents[index].forward.toggle()
            }
        }
    }

    /// Moves the arrows of one wire to another, optionally flipping their
    /// direction when the points of the wire were reversed.
    mutating func reassignCurrents(from oldWire: UUID, to newWire: UUID, reversed: Bool) {
        for index in currents.indices where currents[index].wireID == oldWire {
            currents[index].wireID = newWire
            if reversed { currents[index].forward.toggle() }
        }
    }

    /// Grid points where three or more connections meet, drawn as junction dots.
    var junctions: [GridPoint] {
        var counts: [GridPoint: Int] = [:]
        for wire in wires {
            counts[wire.start, default: 0] += 1
            counts[wire.end, default: 0] += 1
        }
        for component in components {
            counts[component.start, default: 0] += 1
            counts[component.end, default: 0] += 1
        }
        for ground in grounds {
            counts[ground.position, default: 0] += 1
        }
        // An endpoint landing in the middle of a wire forms a T-junction,
        // so the passing wire counts as two connections at that point.
        for point in counts.keys {
            for wire in wires where wire.passesThrough(point) {
                counts[point, default: 0] += 2
            }
        }
        return counts.filter { $0.value >= 3 }.map(\.key)
    }

    /// Whether a new wire ending at `point` would connect to something:
    /// a component terminal, a wire endpoint, or the middle of a wire.
    func isConnectionPoint(_ point: GridPoint) -> Bool {
        components.contains { $0.start == point || $0.end == point }
            || grounds.contains { $0.position == point }
            || wires.contains { $0.start == point || $0.end == point || $0.passesThrough(point) }
    }

    /// The index of the wire with a loose ("blind") end at `point`, i.e. an end
    /// that nothing else connects to. A new wire drawn from there continues it.
    func danglingWireIndex(at point: GridPoint) -> Int? {
        let touching = wires.indices.filter { wires[$0].start == point || wires[$0].end == point }
        guard touching.count == 1, let index = touching.first else { return nil }
        let wire = wires[index]
        guard wire.start != wire.end else { return nil }
        if components.contains(where: { $0.start == point || $0.end == point }) { return nil }
        if grounds.contains(where: { $0.position == point }) { return nil }
        if wires.contains(where: { $0.passesThrough(point) }) { return nil }
        return index
    }

    // MARK: Placing components on wires

    /// Cuts the part of any wire running underneath a component, so the
    /// component replaces it: the wire pieces on either side end at the
    /// component's terminals.
    mutating func cutWires(under component: CircuitComponent) {
        let a = component.start
        let b = component.end
        let isHorizontal = a.y == b.y
        func along(_ p: GridPoint) -> Int { isHorizontal ? p.x : p.y }
        func point(at position: Int) -> GridPoint {
            isHorizontal ? GridPoint(x: position, y: a.y) : GridPoint(x: a.x, y: position)
        }
        let low = min(along(a), along(b))
        let high = max(along(a), along(b))

        /// The first segment lying on the component's line and overlapping it.
        func overlap(in wire: Wire) -> (segment: Int, low: Int, high: Int)? {
            for (index, (p, q)) in wire.segments.enumerated() {
                let onLine = isHorizontal ? (p.y == a.y && q.y == a.y) : (p.x == a.x && q.x == a.x)
                guard onLine else { continue }
                let cutLow = max(low, min(along(p), along(q)))
                let cutHigh = min(high, max(along(p), along(q)))
                if cutHigh > cutLow { return (index, cutLow, cutHigh) }
            }
            return nil
        }

        var pending = wires
        var result: [Wire] = []
        while let wire = pending.popLast() {
            guard let cut = overlap(in: wire) else {
                result.append(wire)
                continue
            }
            let p = wire.points[cut.segment]
            let q = wire.points[cut.segment + 1]
            let runsForward = along(q) > along(p)
            let before = Array(wire.points[...cut.segment]) + [point(at: runsForward ? cut.low : cut.high)]
            let after = [point(at: runsForward ? cut.high : cut.low)] + Array(wire.points[(cut.segment + 1)...])

            // The first remaining piece keeps the wire's id; pieces are checked again.
            var pieces: [Wire] = []
            for points in [before, after].map(Circuit.normalized) where points.count >= 2 {
                pieces.append(pieces.isEmpty ? Wire(id: wire.id, points: points) : Wire(points: points))
            }
            pending += pieces

            for index in currents.indices.reversed() where currents[index].wireID == wire.id {
                let anchor = currents[index].anchor
                if let piece = pieces.min(by: {
                    ($0.nearest(to: anchor)?.distance ?? .infinity) < ($1.nearest(to: anchor)?.distance ?? .infinity)
                }) {
                    currents[index].wireID = piece.id
                } else {
                    currents.remove(at: index)
                }
            }
        }
        wires = result
    }

    // MARK: Moving components with attached wires

    /// Moves a component's terminals and drags the ends of attached wires along,
    /// keeping every wire made of horizontal and vertical segments.
    mutating func moveComponent(id: UUID, start newStart: GridPoint, end newEnd: GridPoint) {
        moveComponents([id: (newStart, newEnd)])
    }

    /// Moves several components (new start and end per id) and ground symbols
    /// (new position per id) at once. Wires in `excludedWires` are left alone;
    /// the caller moves those itself.
    mutating func moveComponents(
        _ targets: [UUID: (start: GridPoint, end: GridPoint)],
        grounds groundTargets: [UUID: GridPoint] = [:],
        excludingWires excludedWires: Set<UUID> = []
    ) {
        var moves: [GridPoint: GridPoint] = [:]
        for index in components.indices {
            guard let target = targets[components[index].id] else { continue }
            moves[components[index].start] = target.start
            moves[components[index].end] = target.end
            components[index].start = target.start
            components[index].end = target.end
        }
        for index in grounds.indices {
            guard let target = groundTargets[grounds[index].id] else { continue }
            moves[grounds[index].position] = target
            grounds[index].position = target
        }
        guard moves.contains(where: { $0.key != $0.value }) else { return }

        for wireIndex in wires.indices where !excludedWires.contains(wires[wireIndex].id) {
            let old = wires[wireIndex]
            let others = anchorPoints(excludingWire: old.id)
            let banded = Circuit.rubberBand(old.points, moves: moves, anchors: others)
            wires[wireIndex].points = banded == old.points
                ? banded
                : slidingJunctions(of: banded, original: old.points, wireID: old.id)
            if wires[wireIndex].points != old.points {
                retargetCurrents(onWire: old.id, from: old)
            }
        }
    }

    /// Where an unmoved end of a rubber-banded wire sits on another wire and
    /// the wire now runs back along that wire, the junction slides along to
    /// where the wire leaves it, so the wire doesn't lie on top of the other.
    private func slidingJunctions(of points: [GridPoint], original: [GridPoint], wireID: UUID) -> [GridPoint] {
        let hostSegments = wires.filter { $0.id != wireID }.flatMap(\.segments)

        /// Trims the part of the first segment that lies on another wire.
        func slideFirst(_ points: [GridPoint]) -> [GridPoint] {
            guard points.count >= 2 else { return points }
            let end = points[0]
            let next = points[1]
            let isHorizontal = end.y == next.y
            func along(_ p: GridPoint) -> Int { isHorizontal ? p.x : p.y }
            for (p, q) in hostSegments {
                let onLine = isHorizontal ? (p.y == end.y && q.y == end.y) : (p.x == end.x && q.x == end.x)
                guard onLine else { continue }
                let low = min(along(p), along(q))
                let high = max(along(p), along(q))
                guard (low...high).contains(along(end)) else { continue }
                // The furthest point towards `next` still on the other wire.
                let target = min(max(along(next), low), high)
                guard target != along(end) else { continue }
                var result = points
                result[0] = isHorizontal ? GridPoint(x: target, y: end.y) : GridPoint(x: end.x, y: target)
                result = Circuit.normalized(result)
                return result.count >= 2 ? result : points
            }
            return points
        }

        var result = points
        if result.first == original.first { result = slideFirst(result) }
        if result.last == original.last { result = slideFirst(result.reversed()).reversed() }
        return result
    }

    /// Points where something other than the given wire is attached.
    func anchorPoints(excludingWire id: UUID) -> Set<GridPoint> {
        var anchors = Set<GridPoint>()
        for component in components {
            anchors.insert(component.start)
            anchors.insert(component.end)
        }
        for wire in wires where wire.id != id {
            anchors.insert(wire.start)
            anchors.insert(wire.end)
        }
        anchors.formUnion(probes.map(\.position))
        anchors.formUnion(probes.compactMap(\.negative))
        anchors.formUnion(grounds.map(\.position))
        return anchors
    }

    /// Returns the wire's points with its ends moved according to `moves`.
    private static func rubberBand(
        _ points: [GridPoint],
        moves: [GridPoint: GridPoint],
        anchors: Set<GridPoint>
    ) -> [GridPoint] {
        guard let first = points.first, let last = points.last else { return points }
        let newFirst = moves[first]
        let newLast = moves[last]
        if newFirst == nil && newLast == nil { return points }

        // Both ends move by the same offset: the whole wire just translates.
        if let newFirst, let newLast, newFirst - first == newLast - last {
            return points.map { $0 + (newFirst - first) }
        }

        var result = points
        if let newFirst {
            result = dragFirstPoint(of: result, to: newFirst, anchors: anchors)
        }
        if let newLast {
            result = dragFirstPoint(of: result.reversed(), to: newLast, anchors: anchors).reversed()
        }
        return normalized(result)
    }

    /// Moves the first point to `target`. If the next point is a free bend,
    /// it slides along so the first segment keeps its direction; otherwise a
    /// new corner is inserted.
    private static func dragFirstPoint(of points: [GridPoint], to target: GridPoint, anchors: Set<GridPoint>) -> [GridPoint] {
        var points = points
        guard points.count >= 2 else {
            if !points.isEmpty { points[0] = target }
            return points
        }
        let old = points[0]
        let neighbor = points[1]
        let isHorizontal = old.y == neighbor.y && old != neighbor
        let neighborIsFree = points.count > 2 && !anchors.contains(neighbor)

        points[0] = target
        if neighborIsFree {
            if isHorizontal {
                points[1].y = target.y
            } else {
                points[1].x = target.x
            }
        } else if target.x != neighbor.x && target.y != neighbor.y {
            // Keep the segment at the moved end in its original direction.
            let corner = isHorizontal
                ? GridPoint(x: neighbor.x, y: target.y)
                : GridPoint(x: target.x, y: neighbor.y)
            points.insert(corner, at: 1)
        }
        return points
    }

    /// Moves the points at `indices` by `offset`, inserting corners so the wire
    /// stays made of horizontal and vertical segments and stays connected to
    /// its unmoved points. A moved end that something else is attached to
    /// (listed in `anchors`) keeps a short connection back to its old place.
    static func dragPoints(_ points: [GridPoint], moving indices: Set<Int>, by offset: GridPoint, anchors: Set<GridPoint>) -> [GridPoint] {
        let count = points.count
        guard count >= 2, !indices.isEmpty, offset != GridPoint(x: 0, y: 0) else { return points }

        var result: [GridPoint] = []
        /// Adds a corner between two points when they aren't on a line. The
        /// corner keeps the given orientation at the end that didn't move.
        func connect(_ last: GridPoint, lastMoved: Bool, _ next: GridPoint, vertical: Bool) {
            guard last.x != next.x, last.y != next.y else { return }
            let (fixed, moved) = lastMoved ? (next, last) : (last, next)
            result.append(vertical ? GridPoint(x: fixed.x, y: moved.y) : GridPoint(x: moved.x, y: fixed.y))
        }

        for index in 0..<count {
            let original = points[index]
            let isMoved = indices.contains(index)
            let current = isMoved ? original + offset : original

            if index == 0 {
                if isMoved, anchors.contains(original) {
                    // Stub from the old end, perpendicular to the first segment.
                    result.append(original)
                    let firstIsVertical = points[0].x == points[1].x
                    connect(original, lastMoved: false, current, vertical: !firstIsVertical)
                }
            } else if let last = result.last {
                let wasVertical = points[index - 1].x == original.x
                connect(last, lastMoved: indices.contains(index - 1), current, vertical: wasVertical)
            }
            result.append(current)

            if index == count - 1, isMoved, anchors.contains(original) {
                let lastIsVertical = points[count - 2].x == points[count - 1].x
                connect(current, lastMoved: true, original, vertical: !lastIsVertical)
                result.append(original)
            }
        }
        return normalized(result)
    }

    /// Removes repeated points and support points that lie on a straight line.
    static func normalized(_ points: [GridPoint]) -> [GridPoint] {
        var result: [GridPoint] = []
        for point in points where result.last != point {
            result.append(point)
        }
        var index = 1
        while index < result.count - 1 {
            let a = result[index - 1], b = result[index], c = result[index + 1]
            if (a.x == b.x && b.x == c.x) || (a.y == b.y && b.y == c.y) {
                result.remove(at: index)
                index = max(1, index - 1)
            } else {
                index += 1
            }
        }
        return result
    }

    /// Whether `point` lies strictly between `a` and `b` on an axis-aligned segment.
    static func point(_ point: GridPoint, isInteriorOf a: GridPoint, _ b: GridPoint) -> Bool {
        if a.x == b.x, point.x == a.x {
            return point.y > min(a.y, b.y) && point.y < max(a.y, b.y)
        }
        if a.y == b.y, point.y == a.y {
            return point.x > min(a.x, b.x) && point.x < max(a.x, b.x)
        }
        return false
    }

    /// E.g. "V = μ · Vs" for a voltage-controlled voltage source.
    func controlDescription(of component: CircuitComponent) -> String {
        let control = component.controlLabel
        return "\(component.kind.setsVoltage ? "V" : "I") = \(component.kind.gainSymbol) · \(control)"
    }

    /// Returns the next free name such as "R3" for the given prefix.
    /// Whether a component, voltage point or current already has this name.
    func isNameUsed(_ name: String) -> Bool {
        components.contains { $0.name == name } || probes.contains { $0.name == name } || currents.contains { $0.name == name }
    }

    /// The top-left corner of everything's grid points, or `nil` when empty.
    var topLeft: GridPoint? {
        var points = components.flatMap { [$0.start, $0.end] }
        points += wires.flatMap(\.points)
        points += probes.map(\.position)
        points += probes.compactMap(\.negative)
        points += grounds.map(\.position)
        points += equivalents.flatMap { [$0.start, $0.end] }
        points += senses.map(\.gridPoint)
        points += textBoxes.map(\.position)
        points += excludedAreas.flatMap { [$0.from, $0.to] }
        points += meshMarkers.map(\.position)
        points += groupAreas.flatMap { [$0.from, $0.to] }
        guard let minX = points.map(\.x).min(), let minY = points.map(\.y).min() else { return nil }
        return GridPoint(x: minX, y: minY)
    }

    /// Moves every item by `offset`.
    mutating func translate(by offset: GridPoint) {
        let dx = Double(offset.x)
        let dy = Double(offset.y)
        for index in components.indices {
            components[index].start = components[index].start + offset
            components[index].end = components[index].end + offset
        }
        for index in wires.indices {
            wires[index].points = wires[index].points.map { $0 + offset }
        }
        for index in probes.indices {
            probes[index].position = probes[index].position + offset
            probes[index].negative = probes[index].negative.map { $0 + offset }
        }
        for index in grounds.indices {
            grounds[index].position = grounds[index].position + offset
        }
        for index in equivalents.indices {
            equivalents[index].start = equivalents[index].start + offset
            equivalents[index].end = equivalents[index].end + offset
        }
        for index in senses.indices {
            senses[index].x += dx
            senses[index].y += dy
        }
        for index in currents.indices {
            currents[index].anchorX += dx
            currents[index].anchorY += dy
        }
        for index in textBoxes.indices {
            textBoxes[index].position = textBoxes[index].position + offset
        }
        for index in excludedAreas.indices {
            excludedAreas[index].from = excludedAreas[index].from + offset
            excludedAreas[index].to = excludedAreas[index].to + offset
        }
        for index in meshMarkers.indices {
            meshMarkers[index].position = meshMarkers[index].position + offset
        }
        for index in groupAreas.indices {
            groupAreas[index].from = groupAreas[index].from + offset
            groupAreas[index].to = groupAreas[index].to + offset
        }
    }

    /// The next free group name: "Gruppe 1", "Gruppe 2", …
    func nextGroupName() -> String {
        let used = Set(groupAreas.map(\.name))
        var index = 1
        while used.contains("Gruppe \(index)") { index += 1 }
        return "Gruppe \(index)"
    }

    /// Only what lies entirely inside a group: what the Maple window works
    /// with when that group is chosen.
    func inside(_ group: GroupArea) -> Circuit {
        func isInside(_ points: [GridPoint]) -> Bool { points.allSatisfy(group.contains) }
        var result = self
        result.components.removeAll { !isInside([$0.start, $0.end]) }
        let componentIDs = Set(result.components.map(\.id))
        result.senses.removeAll { !componentIDs.contains($0.ownerID) }
        result.wires.removeAll { !isInside($0.points) }
        let wireIDs = Set(result.wires.map(\.id))
        result.currents.removeAll { !wireIDs.contains($0.wireID) || !group.contains($0.anchor) }
        result.probes.removeAll { !isInside([$0.position] + ($0.negative.map { [$0] } ?? [])) }
        result.grounds.removeAll { !isInside([$0.position]) }
        result.equivalents.removeAll { !isInside([$0.start, $0.end]) }
        result.meshMarkers.removeAll { !isInside([$0.position]) }
        return result
    }

    /// The next free mesh current name: I_{A}, I_{B}, … (not meaning the same
    /// in formulas as another name).
    func nextMeshName() -> String {
        let used = Set((components.map(\.name) + probes.map(\.name) + currents.map(\.name) + meshMarkers.map(\.name)).map(FormulaParts.key))
        let letter = WalkFormat.letters.first { !used.contains("I" + $0) } ?? "X"
        return "I_{\(letter)}"
    }

    /// The circuit without what lies entirely inside an excluded area: what
    /// the calculation and the Maple output work with.
    func excludingAreas() -> Circuit {
        guard !excludedAreas.isEmpty else { return self }
        func isExcluded(_ points: [GridPoint]) -> Bool {
            excludedAreas.contains { area in points.allSatisfy(area.contains) }
        }
        var result = self
        result.components.removeAll { isExcluded([$0.start, $0.end]) }
        let componentIDs = Set(result.components.map(\.id))
        result.senses.removeAll { !componentIDs.contains($0.ownerID) }
        result.wires.removeAll { isExcluded($0.points) }
        let wireIDs = Set(result.wires.map(\.id))
        result.currents.removeAll { arrow in
            !wireIDs.contains(arrow.wireID) || excludedAreas.contains { $0.contains(arrow.anchor) }
        }
        result.probes.removeAll { isExcluded([$0.position] + ($0.negative.map { [$0] } ?? [])) }
        result.grounds.removeAll { isExcluded([$0.position]) }
        result.equivalents.removeAll { isExcluded([$0.start, $0.end]) }
        return result
    }

    func nextName(prefix: String) -> String {
        let used = Set(components.map(\.name) + probes.map(\.name) + currents.map(\.name))
        var index = 1
        while used.contains("\(prefix)\(index)") { index += 1 }
        return "\(prefix)\(index)"
    }

    /// The next free name for a voltage drop: V_{A}, V_{B}, … It mustn't mean
    /// the same in formulas as another name (V_{A} and VA are both "VA"), except
    /// the one of the probe `excluding`, which is being renamed.
    func nextVoltageDropName(excluding id: UUID? = nil) -> String {
        let used = Set(
            (components.map(\.name) + probes.filter { $0.id != id }.map(\.name) + currents.map(\.name))
                .map(FormulaParts.key)
        )
        let letters = (UnicodeScalar("A").value...UnicodeScalar("Z").value).compactMap { UnicodeScalar($0).map(String.init) }
        var round = 0
        while true {
            for letter in letters {
                let suffix = letter + (round == 0 ? "" : String(round))
                if !used.contains("V" + suffix) { return "V_{\(suffix)}" }
            }
            round += 1
        }
    }

    /// Returns the next free voltage point name: VA, VB, … VZ, then VA1, VB1, …
    func nextProbeName() -> String {
        let used = Set(components.map(\.name) + probes.map(\.name) + currents.map(\.name))
        let letters = (UnicodeScalar("A").value...UnicodeScalar("Z").value).compactMap { UnicodeScalar($0).map(String.init) }
        var suffix = ""
        var round = 0
        while true {
            if let free = letters.first(where: { !used.contains("V" + $0 + suffix) }) {
                return "V" + free + suffix
            }
            round += 1
            suffix = "\(round)"
        }
    }
}

// MARK: - Value formatting and parsing

nonisolated enum SIValue {
    private static let prefixes: [(symbol: String, factor: Double)] = [
        ("G", 1e9), ("M", 1e6), ("k", 1e3), ("", 1), ("m", 1e-3), ("µ", 1e-6), ("n", 1e-9), ("p", 1e-12)
    ]

    /// Formats a value with an SI prefix, e.g. 4700 → "4,7 kΩ".
    static func format(_ value: Double?, unit: String) -> String {
        guard let value else { return "? \(unit)" }
        // Ratios like V/V are shown without SI prefixes.
        if unit == "V/V" || unit == "A/A" || unit.isEmpty {
            // No thousands separator: "1.500" would read back as 1,5.
            let number = value.formatted(.number.precision(.significantDigits(1...4)).grouping(.never))
            return unit.isEmpty ? number : "\(number) \(unit)"
        }
        if value == 0 { return "0 \(unit)" }
        let magnitude = abs(value)
        let prefix = prefixes.first { magnitude >= $0.factor * 0.999_999 } ?? prefixes[prefixes.count - 1]
        let scaled = value / prefix.factor
        return "\(scaled.formatted(.number.precision(.significantDigits(1...4)))) \(prefix.symbol)\(unit)"
    }

    /// Parses user input like "4.7k", "4,7 kΩ", "10m" or "2.2 µA", and
    /// ratios with a prefix on either unit: "3 mA/V" = 0.003, "5 V/mA" = 5000.
    /// Returns `nil` for empty or invalid input.
    static func parse(_ text: String) -> Double? {
        var string = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
        // A ratio: the prefix of the unit after "/" divides.
        var divisor = 1.0
        if let slash = string.lastIndex(of: "/") {
            var denominator = String(string[string.index(after: slash)...])
            string = String(string[..<slash])
            guard let unit = Self.unitSymbols.first(where: { denominator.hasSuffix($0) }) else { return nil }
            denominator.removeLast(unit.count)
            if !denominator.isEmpty {
                guard let factor = prefixFactor(denominator) else { return nil }
                divisor = factor
            }
        }
        // Drop a trailing unit symbol.
        if let unit = Self.unitSymbols.first(where: { string.hasSuffix($0) }) {
            string.removeLast(unit.count)
        }
        guard !string.isEmpty else { return nil }

        var factor = 1.0
        if let last = string.last, let prefix = prefixFactor(String(last)) {
            factor = prefix
            string.removeLast()
        }
        guard let number = Double(string) else { return nil }
        return number * factor / divisor
    }

    /// Unit symbols that may follow a value, longest first.
    private static let unitSymbols = ["ohm", "Ohm", "Ω", "S", "V", "A"]

    /// The factor of an SI prefix; "u" and the Greek μ also mean micro.
    private static func prefixFactor(_ symbol: String) -> Double? {
        let symbol = symbol == "u" || symbol == "μ" ? "µ" : symbol
        return prefixes.first { !$0.symbol.isEmpty && $0.symbol == symbol }?.factor
    }

    /// The number at the start of a value as typed, without its unit:
    /// "3 mA/V" → "3", "-4,7k" → "-4,7".
    static func numberPart(of text: String) -> String {
        String(text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || "+-.,".contains($0) })
    }
}

nonisolated extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }

    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / lengthSquared))
        return distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

// MARK: - Global definitions from text boxes

extension Circuit {
    /// Whether the only difference to `other` is in the freehand lines.
    /// (Also true when nothing differs at all.)
    func differsOnlyInStrokes(from other: Circuit) -> Bool {
        components == other.components && wires == other.wires && probes == other.probes
            && currents == other.currents && grounds == other.grounds && senses == other.senses
            && equivalents == other.equivalents && textBoxes == other.textBoxes
            && inheritedValues == other.inheritedValues && excludedAreas == other.excludedAreas
    }

    /// Every component, voltage point and current as (id, formula name, value, unit).
    private var namedValues: [(id: UUID, key: String, value: Double?, unit: PhysicalUnit?)] {
        components.map { ($0.id, FormulaParts.key($0.name), $0.value, PhysicalUnit(symbol: $0.kind.unit)) }
            + probes.map { ($0.id, FormulaParts.key($0.name), $0.value, PhysicalUnit.volt) }
            + currents.map { ($0.id, FormulaParts.key($0.name), $0.value, PhysicalUnit.ampere) }
    }

    /// Formula names of things whose value was typed in. A text box can't
    /// give them another value.
    var typedInNames: Set<String> {
        Set(namedValues.filter { $0.value != nil && !inheritedValues.contains($0.id) }.map(\.key))
    }

    /// The values given by "!name := …" lines in text boxes, by formula name,
    /// worked out in document order. A definition can use typed-in values and
    /// earlier definitions, but not the value it's giving itself. Names whose
    /// value was typed in are skipped: the typed-in value wins.
    func globalDefinitions() -> [String: Quantity] {
        let locked = typedInNames
        var variables: [String: Quantity] = [:]
        for item in namedValues where item.value != nil && !inheritedValues.contains(item.id) {
            variables[item.key] = Quantity(item.value ?? 0, unit: item.unit)
        }
        var globals: [String: Quantity] = [:]
        for line in textBoxes.flatMap(\.lines) where line.isMath {
            let parts = FormulaParts(line.text)
            guard parts.isGlobal, let key = parts.nameKey, !locked.contains(key), !parts.expression.isEmpty,
                  case .success(let quantity) = MathEvaluator.evaluate(LatexParser.parse(parts.expression), variables: variables)
            else { continue }
            variables[key] = quantity
            globals[key] = quantity
        }
        return globals
    }

    /// The circuit with the global definitions' values given to everything of
    /// the same name that has no typed-in value. Values inherited from a
    /// definition that's gone (e.g. its "!" was deleted) are removed again.
    func applyingGlobalDefinitions(_ globals: [String: Quantity]) -> Circuit {
        var result = self
        /// The new value for an item, or `nil` to leave it as it is.
        func inherit(_ id: UUID, name: String, value: Double?) -> Double?? {
            let definition = globals[FormulaParts.key(name)]
            if result.inheritedValues.contains(id) {
                guard let definition else {
                    result.inheritedValues.remove(id)
                    return .some(nil)
                }
                return definition.value == value ? nil : .some(definition.value)
            }
            guard value == nil, let definition else { return nil }
            result.inheritedValues.insert(id)
            return .some(definition.value)
        }
        for index in result.components.indices {
            let item = result.components[index]
            if let value = inherit(item.id, name: item.name, value: item.value) { result.components[index].value = value }
        }
        for index in result.probes.indices {
            let item = result.probes[index]
            if let value = inherit(item.id, name: item.name, value: item.value) { result.probes[index].value = value }
        }
        for index in result.currents.indices {
            let item = result.currents[index]
            if let value = inherit(item.id, name: item.name, value: item.value) { result.currents[index].value = value }
        }
        // Forget ids of items that were deleted.
        let ids = Set(result.components.map(\.id) + result.probes.map(\.id) + result.currents.map(\.id))
        result.inheritedValues.formIntersection(ids)
        return result
    }
}
