import SwiftUI

/// The active drawing tool.
enum Tool: Hashable, CaseIterable, Identifiable {
    case select
    case wire
    case component(ComponentKind)
    /// Places a ground reference (0 V).
    case ground
    /// Marks the current flowing in a wire with a named arrow.
    case current
    case probe
    /// Draws a circle around a component to show the power it absorbs.
    case power
    /// Combines tapped resistors into one equivalent resistance (Req).
    case equivalent
    /// Places a text box for notes and calculations.
    case text
    /// Marks a mesh current (name and direction) for the mesh method.
    case mesh
    /// Draws a named, tinted box that groups part of the sheet for the Maple window.
    case groupArea

    static var allCases: [Tool] {
        [.select, .wire] + ComponentKind.allCases.map { .component($0) } + [.ground, .current, .probe, .power, .mesh, .equivalent, .text, .groupArea]
    }

    var id: String {
        switch self {
        case .select: "select"
        case .wire: "wire"
        case .component(let kind): kind.rawValue
        case .ground: "ground"
        case .current: "current"
        case .probe: "probe"
        case .power: "power"
        case .equivalent: "equivalent"
        case .text: "text"
        case .mesh: "mesh"
        case .groupArea: "groupArea"
        }
    }

    /// One of the controlled sources, which share a button in the palette.
    var isDependentSource: Bool {
        if case .component(let kind) = self { return kind.isDependent }
        return false
    }

    var displayName: String {
        switch self {
        case .select: "Vælg"
        case .wire: "Ledning"
        case .component(let kind): kind.displayName
        case .ground: "Stel (0 V)"
        case .current: "Strøm i ledning"
        case .probe: "Spændingspunkt"
        case .power: "Effekt i komponent"
        case .equivalent: "Samlet modstand (Req)"
        case .text: "Tekst og udregning"
        case .mesh: "Maskestrøm"
        case .groupArea: "Gruppe"
        }
    }
}

/// The item currently selected on the schematic.
nonisolated enum Selection: Hashable {
    case component(UUID)
    /// A whole wire with all its segments.
    case wire(UUID)
    /// A single straight segment of a wire, from bend to bend.
    case wireSegment(UUID, Int)
    /// A voltage point, or the + point of a voltage drop.
    case probe(UUID)
    /// The − point of a voltage drop (by probe id).
    case probeMinus(UUID)
    /// The movable label of a voltage drop (by probe id).
    case probeLabel(UUID)
    case currentArrow(UUID)
    case ground(UUID)
    /// A controlled source's + / − / Is sense marker.
    case sense(UUID)
    /// The movable "Vs" label of a voltage-controlled source (by source id).
    case senseLabel(UUID)
    /// The grey symbol of an equivalent resistance (Req).
    case equivalent(UUID)
    /// A text box with notes and calculations.
    case textBox(UUID)
    /// A box whose contents are left out of the calculation.
    case excludedArea(UUID)
    /// A mesh current arrow.
    case meshMarker(UUID)
    /// A named box grouping part of the sheet.
    case groupArea(UUID)
    /// Several items selected with an area selection
    /// (components, whole wires and probes).
    case group(Set<Selection>)
}

/// Owns the circuit being edited along with tool, selection and undo state.
@Observable
final class CircuitEditor {
    /// Distance between grid dots in points at zoom level 1.
    static let gridSpacing: CGFloat = 20
    /// Length (in grid units) of a component placed with a single tap.
    static let defaultComponentLength = 4

    private(set) var circuit = Circuit() {
        didSet {
            // Freehand lines don't affect the calculation; skip the work while
            // drawing and erasing.
            guard !circuit.differsOnlyInStrokes(from: oldValue) else { return }
            // Values given by "!name := …" in text boxes follow along with
            // every change. (Applying them may run this observer once more,
            // which then finds nothing left to apply.)
            let globals = circuit.globalDefinitions()
            let applied = circuit.applyingGlobalDefinitions(globals)
            if applied != circuit { circuit = applied }
            inheritedNames = Set(globals.keys)
            documentDefinitions = globals
            if circuit != oldValue {
                // What lies in an excluded area doesn't take part.
                let calculated = circuit.excludingAreas()
                solution = CircuitSolver.solve(calculated)
                netlist = Netlist(calculated)
                equivalentResults = Dictionary(uniqueKeysWithValues: calculated.equivalents.map {
                    ($0.id, CircuitSolver.equivalentResistance(
                        between: $0.start, and: $0.end, in: calculated, netlist: netlist, solution: solution
                    ))
                })
            }
        }
    }
    /// Formula names whose value comes from a "!name := …" line in a text box.
    private(set) var inheritedNames: Set<String> = []
    /// The values of all "!name := …" lines, usable in every text box.
    private(set) var documentDefinitions: [String: Quantity] = [:]

    /// Whether a component, voltage point or current gets its value from a
    /// global definition in a text box.
    func isInherited(_ name: String) -> Bool {
        inheritedNames.contains(Self.formulaKey(name))
    }

    /// Whether something named `key` (a formula name) has a typed-in value,
    /// which text boxes can't overwrite.
    func hasTypedInValue(_ key: String) -> Bool {
        circuit.typedInNames.contains(key)
    }

    /// Values filled in by the automatic calculation, and what's missing.
    private(set) var solution = CircuitSolution()
    /// The nodes of the circuit.
    private(set) var netlist = Netlist(Circuit())
    /// The value of each equivalent resistance (Req), by id.
    private(set) var equivalentResults: [UUID: EquivalentResult] = [:]
    var tool: Tool = .wire {
        didSet {
            // Switching tool keeps whatever part of a wire has been routed so far,
            // and forgets a Req's first point.
            if tool != oldValue {
                finishWire()
                pendingEquivalentPoint = nil
                placesVoltageDrops = false
            }
        }
    }

    /// Point A of the Req being placed, while waiting for point B.
    private(set) var pendingEquivalentPoint: GridPoint?
    var selection: Selection?

    /// Points of the wire currently being routed click by click.
    /// Empty when no wire is in progress.
    private(set) var routing: [GridPoint] = []
    var isRouting: Bool { !routing.isEmpty }

    /// Orientation for components placed with a tap, in quarter turns clockwise
    /// (0 = start→end pointing right). Changed with the R key.
    private(set) var placementRotation = 0

    /// The circuit as it was when the current move began; moves are applied
    /// relative to it so rubber-banded wires don't accumulate extra bends.
    private var moveOrigin: Circuit?
    /// What the current move is moving, so components can cut wires they're dropped on.
    private var movingItem: Selection?

    /// The circuit when a symbol editor opened, to group its edits into one undo step.
    private var editSnapshot: Circuit?

    /// The window's undo manager, set by the view from the environment.
    /// The document app relies on registered undo actions to detect
    /// unsaved changes and autosave.
    var undoManager: UndoManager?

    /// Bumped whenever the undo state changes, so views showing
    /// `canUndo`/`canRedo` refresh (`UndoManager` isn't observable).
    private var undoVersion = 0

    var canUndo: Bool {
        _ = undoVersion
        return undoManager?.canUndo ?? false
    }
    var canRedo: Bool {
        _ = undoVersion
        return undoManager?.canRedo ?? false
    }

    /// Replaces the whole circuit, e.g. when a file is opened. Not undoable.
    func load(_ circuit: Circuit) {
        self.circuit = circuit
        routing = []
        selection = nil
        pendingEquivalentPoint = nil
    }

    // MARK: Viewport

    /// Zoom factor and pan offset of the sheet: screen = world * scale + offset.
    var scale: CGFloat = 1
    private(set) var offset = CGSize(width: 40, height: 40)

    /// The size of the sheet on screen, and of the page in grid units.
    /// Set by the canvas so panning can be kept within the page.
    var viewSize: CGSize = .zero {
        didSet { setOffset(offset) }
    }
    var pageSize = GridPoint(x: PageSize.defaultWidth, y: PageSize.defaultHeight) {
        didSet { setOffset(offset) }
    }

    /// Moves the view, keeping the middle of the screen on the page, so the
    /// edge of the page can at most reach the middle of the screen.
    func setOffset(_ newOffset: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else {
            offset = newOffset
            return
        }
        let width = CGFloat(pageSize.x) * Self.gridSpacing * scale
        let height = CGFloat(pageSize.y) * Self.gridSpacing * scale
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        // screen = world · scale + offset, and the world point at the center
        // must lie between 0 and the page's width and height.
        offset = CGSize(
            width: min(center.x, max(center.x - width, newOffset.width)),
            height: min(center.y, max(center.y - height, newOffset.height))
        )
    }

    func resetView() {
        scale = 1
        setOffset(CGSize(width: 40, height: 40))
    }

    /// Zooms by `factor` around a point in screen coordinates (e.g. the view center).
    func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let newScale = min(4, max(0.25, scale * factor))
        let world = CGPoint(x: (anchor.x - offset.width) / scale, y: (anchor.y - offset.height) / scale)
        scale = newScale
        setOffset(CGSize(width: anchor.x - world.x * newScale, height: anchor.y - world.y * newScale))
    }

    // MARK: Undo

    /// Records the current state so the next change can be undone.
    func checkpoint() {
        registerUndo(restoring: circuit)
    }

    /// Registers an undo step that restores `previous`. Undoing registers the
    /// opposite step, which the undo manager turns into redo.
    private func registerUndo(restoring previous: Circuit) {
        undoManager?.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                let current = editor.circuit
                editor.circuit = previous
                editor.routing = []
                editor.validateSelection()
                editor.registerUndo(restoring: current)
            }
        }
        undoVersion += 1
    }

    /// Applies a change and makes it undoable, if it changed anything.
    /// Used for small edits such as typing a name in the inspector.
    func edit(_ change: () -> Void) {
        let before = circuit
        change()
        if circuit != before { registerUndo(restoring: before) }
    }

    /// Call when an editor for names, values or notes opens, so all its
    /// changes can be undone in one step.
    func beginEdit() {
        editSnapshot = circuit
    }

    /// Call when the editor closes. Records one undo step if anything changed.
    func endEdit() {
        if let editSnapshot, editSnapshot != circuit {
            registerUndo(restoring: editSnapshot)
        }
        editSnapshot = nil
    }

    func undo() {
        undoManager?.undo()
        undoVersion += 1
    }

    func redo() {
        undoManager?.redo()
        undoVersion += 1
    }

    /// Whether an item is selected, either on its own or as part of a group.
    func isSelected(_ item: Selection) -> Bool {
        if selection == item { return true }
        if case .group(let items) = selection { return items.contains(item) }
        return false
    }

    private func exists(_ item: Selection) -> Bool {
        switch item {
        case .component(let id): circuit.components.contains { $0.id == id }
        case .wire(let id): circuit.wires.contains { $0.id == id }
        case .wireSegment(let id, let index): circuit.wires.contains { $0.id == id && index < $0.segments.count }
        case .probe(let id): circuit.probes.contains { $0.id == id }
        case .probeMinus(let id), .probeLabel(let id): circuit.probes.contains { $0.id == id && $0.isVoltageDrop }
        case .currentArrow(let id): circuit.currents.contains { $0.id == id }
        case .ground(let id): circuit.grounds.contains { $0.id == id }
        case .sense(let id): circuit.senses.contains { $0.id == id }
        case .senseLabel(let id): circuit.components.contains { $0.id == id }
        case .equivalent(let id): circuit.equivalents.contains { $0.id == id }
        case .textBox(let id): circuit.textBoxes.contains { $0.id == id }
        case .excludedArea(let id): circuit.excludedAreas.contains { $0.id == id }
        case .meshMarker(let id): circuit.meshMarkers.contains { $0.id == id }
        case .groupArea(let id): circuit.groupAreas.contains { $0.id == id }
        case .group(let items): items.contains { exists($0) }
        }
    }

    private func validateSelection() {
        guard let selection else { return }
        if case .group(let items) = selection {
            self.selection = Self.selection(of: items.filter { exists($0) })
            return
        }
        if !exists(selection) { self.selection = nil }
    }

    /// Nothing, a single item or a group, depending on how many items there are.
    private static func selection(of items: Set<Selection>) -> Selection? {
        switch items.count {
        case 0: nil
        case 1: items.first
        default: .group(items)
        }
    }

    /// The selected items as a set.
    private var selectedItems: Set<Selection> {
        switch selection {
        case nil: []
        case .group(let items): items
        case let item?: [item]
        }
    }

    /// ⌘-click: adds an item (e.g. one wire segment) to the selection, or
    /// removes it if it's already selected.
    func toggleSelection(_ item: Selection) {
        var items = selectedItems
        if case .wireSegment(let id, let index) = item, items.contains(.wire(id)),
           let wire = circuit.wires.first(where: { $0.id == id }) {
            // The whole wire was selected: keep all its segments except this one.
            items.remove(.wire(id))
            for segment in wire.segments.indices where segment != index {
                items.insert(.wireSegment(id, segment))
            }
        } else if items.contains(item) {
            items.remove(item)
        } else {
            items.insert(item)
        }
        selection = Self.selection(of: items)
    }

    /// U: extends every selected wire segment to its whole wire.
    func selectWholeWires() {
        let items = selectedItems.map { item -> Selection in
            if case .wireSegment(let id, _) = item { return .wire(id) }
            return item
        }
        selection = Self.selection(of: Set(items))
    }

    /// Selects every item on the sheet (⌘A).
    func selectAll() {
        finishWire()
        var items = Set<Selection>()
        items.formUnion(circuit.components.map { .component($0.id) })
        items.formUnion(circuit.wires.map { .wire($0.id) })
        items.formUnion(circuit.probes.map { .probe($0.id) })
        items.formUnion(circuit.currents.map { .currentArrow($0.id) })
        items.formUnion(circuit.grounds.map { .ground($0.id) })
        items.formUnion(circuit.senses.map { .sense($0.id) })
        items.formUnion(circuit.equivalents.map { .equivalent($0.id) })
        items.formUnion(circuit.textBoxes.map { .textBox($0.id) })
        selection = Self.selection(of: items)
    }

    /// Selects everything lying completely inside a rectangle in world coordinates.
    /// With `adding` (⌘-drag), the items are added to the current selection.
    func selectItems(in rect: CGRect, adding: Bool = false) {
        let spacing = Self.gridSpacing
        func inside(_ p: GridPoint) -> Bool {
            rect.contains(CGPoint(x: CGFloat(p.x) * spacing, y: CGFloat(p.y) * spacing))
        }
        var items = Set<Selection>()
        for component in circuit.components where inside(component.start) && inside(component.end) {
            items.insert(.component(component.id))
        }
        for wire in circuit.wires where wire.points.allSatisfy(inside) {
            items.insert(.wire(wire.id))
        }
        for probe in circuit.probes where inside(probe.position) && probe.negative.map(inside) != false {
            items.insert(.probe(probe.id))
        }
        for ground in circuit.grounds where inside(ground.position) {
            items.insert(.ground(ground.id))
        }
        for equivalent in circuit.equivalents where inside(equivalent.start) && inside(equivalent.end) {
            items.insert(.equivalent(equivalent.id))
        }
        for box in circuit.textBoxes where rect.contains(textBoxRect(box)) {
            items.insert(.textBox(box.id))
        }
        for area in circuit.excludedAreas where inside(area.from) && inside(area.to) {
            items.insert(.excludedArea(area.id))
        }
        for marker in circuit.meshMarkers where inside(marker.position) {
            items.insert(.meshMarker(marker.id))
        }
        for group in circuit.groupAreas where inside(group.from) && inside(group.to) {
            items.insert(.groupArea(group.id))
        }
        for marker in circuit.senses where rect.contains(CGPoint(x: marker.x * spacing, y: marker.y * spacing)) {
            items.insert(.sense(marker.id))
        }
        for arrow in circuit.currents {
            if let placement = circuit.placement(of: arrow),
               rect.contains(CGPoint(x: placement.point.x * spacing, y: placement.point.y * spacing)) {
                items.insert(.currentArrow(arrow.id))
            }
        }
        if adding { items.formUnion(selectedItems) }
        selection = Self.selection(of: items)
    }

    // MARK: Adding items

    /// Adds a wire from `start` to `end`. Diagonal drags become an L-shaped
    /// pair of segments: horizontal first, then vertical.
    func addWire(from start: GridPoint, to end: GridPoint) {
        guard start != end else { return }
        checkpoint()
        let corner = GridPoint(x: end.x, y: start.y)
        circuit.wires.append(Wire(points: Circuit.normalized([start, corner, end])))
    }

    /// ⇧-drag with the wire tool: a closed rectangle of wire with corners at
    /// `a` and `b`, ready for components to be placed on its sides.
    func addRectangleWire(from a: GridPoint, to b: GridPoint) {
        guard a.x != b.x, a.y != b.y else { return }
        finishWire()

        // The rectangle one grid step at a time; steps an existing wire or
        // component already covers are left out, so a shared side isn't
        // drawn twice (and a component on it isn't shorted).
        let corners = [a, GridPoint(x: b.x, y: a.y), b, GridPoint(x: a.x, y: b.y), a]
        var points: [GridPoint] = [a]
        for (from, to) in zip(corners, corners.dropFirst()) {
            let dx = (to.x - from.x).signum(), dy = (to.y - from.y).signum()
            var p = from
            while p != to {
                p = p + GridPoint(x: dx, y: dy)
                points.append(p)
            }
        }
        let occupied = circuit.wires.flatMap(\.segments) + circuit.components.map { ($0.start, $0.end) }
        func isCovered(_ p: GridPoint, _ q: GridPoint) -> Bool {
            occupied.contains { segment in
                [p, q].allSatisfy { $0 == segment.0 || $0 == segment.1 || Circuit.point($0, isInteriorOf: segment.0, segment.1) }
            }
        }
        let steps = points.count - 1
        let covered = (0..<steps).map { isCovered(points[$0], points[$0 + 1]) }
        guard covered.contains(false) else { return }
        checkpoint()

        var added: [Wire] = []
        if !covered.contains(true) {
            added = [Wire(points: corners)]
        } else {
            // Runs of free steps, starting after a covered one so no run is
            // split where the rectangle closes.
            let first = (0..<steps).first { covered[$0] } ?? 0
            var run: [GridPoint] = []
            for offset in 1...steps {
                let step = (first + offset) % steps
                if covered[step] {
                    if run.count >= 2 { added.append(Wire(points: Circuit.normalized(run))) }
                    run = []
                } else {
                    if run.isEmpty { run = [points[step]] }
                    run.append(points[step + 1])
                }
            }
            if run.count >= 2 { added.append(Wire(points: Circuit.normalized(run))) }
        }
        circuit.wires += added
        selection = Self.selection(of: Set(added.map { .wire($0.id) }))
    }

    /// Handles a click with the wire tool. The first click starts a wire; each
    /// following click adds a support point, until a click lands on an existing
    /// connection point (or on the last point again), which finishes the wire.
    func wireClick(at point: GridPoint) {
        guard let last = routing.last else {
            routing = [point]
            return
        }
        if point == last {
            finishWire()
            return
        }
        // Diagonal clicks become an L: horizontal first, then vertical.
        if point.x != last.x && point.y != last.y {
            routing.append(GridPoint(x: point.x, y: last.y))
        }
        routing.append(point)
        if circuit.isConnectionPoint(point) {
            finishWire()
        }
    }

    /// Commits the routed points as one wire, ending at the last support point.
    /// If the wire starts or ends on a loose end of an existing wire, the two
    /// are merged into a single wire.
    func finishWire() {
        defer { routing = [] }
        var points = Circuit.normalized(routing)
        guard points.count >= 2 else { return }
        checkpoint()

        var mergedID: UUID?
        var tailID: UUID?
        var tailReversed = false
        if let index = circuit.danglingWireIndex(at: points[0]) {
            let existing = circuit.wires.remove(at: index)
            let isReversed = existing.end != points[0]
            let head = isReversed ? existing.points.reversed() : existing.points
            points = head + points.dropFirst()
            mergedID = existing.id
            circuit.reassignCurrents(from: existing.id, to: existing.id, reversed: isReversed)
        }
        if let last = points.last, let index = circuit.danglingWireIndex(at: last) {
            let existing = circuit.wires.remove(at: index)
            let isReversed = existing.start != last
            let tail = isReversed ? existing.points.reversed() : existing.points
            points += tail.dropFirst()
            tailID = existing.id
            tailReversed = isReversed
            mergedID = mergedID ?? existing.id
        }

        // Keep the id of a continued wire so a selection of it stays valid.
        var wire = Wire(points: Circuit.normalized(points))
        if let mergedID { wire.id = mergedID }
        if let tailID {
            circuit.reassignCurrents(from: tailID, to: wire.id, reversed: tailReversed)
        }
        circuit.wires.append(wire)
        validateSelection()
    }

    /// Esc: ends a wire in progress or forgets a Req's first point, otherwise
    /// switches to the select tool.
    func escape() {
        if isDrawing {
            isDrawing = false
        } else if isRouting {
            finishWire()
        } else if pendingEquivalentPoint != nil {
            pendingEquivalentPoint = nil
        } else {
            tool = .select
        }
    }

    /// Terminals of a component placed with a tap, centered on `point`
    /// and oriented by `placementRotation`.
    func defaultTerminals(centeredAt point: GridPoint) -> (GridPoint, GridPoint) {
        let half = Self.defaultComponentLength / 2
        var start = point - GridPoint(x: half, y: 0)
        var end = point + GridPoint(x: half, y: 0)
        for _ in 0..<placementRotation {
            start = start.rotatedClockwise(around: point)
            end = end.rotatedClockwise(around: point)
        }
        return (start, end)
    }

    /// R: rotates the placement preview when a component or ground tool is
    /// active, otherwise the selected item.
    func rotate() {
        if case .meshMarker(let id) = selection {
            flipMeshMarker(id: id)
            return
        }
        switch tool {
        case .component, .ground:
            placementRotation = (placementRotation + 1) % 4
        case .mesh:
            meshPlacementClockwise.toggle()
        default:
            switch selection {
            case .component(let id): rotateComponent(id: id)
            case .currentArrow(let id): flipCurrentArrow(id: id)
            case .ground(let id): rotateGround(id: id)
            case .sense(let id): flipSense(id: id)
            default: break
            }
        }
    }

    /// Turns a ground symbol 90° clockwise around its connection point.
    func rotateGround(id: UUID) {
        guard let index = circuit.grounds.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        circuit.grounds[index].rotation = (circuit.grounds[index].rotation + 1) % 4
    }

    /// Reverses the measured direction of a current sense marker (Is).
    func flipSense(id: UUID) {
        guard let index = circuit.senses.firstIndex(where: { $0.id == id }),
              circuit.senses[index].kind == .current else { return }
        checkpoint()
        circuit.senses[index].flipped.toggle()
    }

    /// Adds the sense markers of a new controlled source beside it, for the
    /// user to drag to where the voltage or current should be measured.
    private func addSenseMarkers(for component: CircuitComponent) {
        let delta = component.end - component.start
        // A few grid units to the side of the source.
        let side = delta.x == 0 ? GridPoint(x: -3, y: 0) : GridPoint(x: 0, y: -3)
        if component.kind.isVoltageControlled {
            let plus = component.end + side
            let minus = component.start + side
            circuit.senses.append(SenseMarker(ownerID: component.id, kind: .plus, x: Double(plus.x), y: Double(plus.y)))
            circuit.senses.append(SenseMarker(ownerID: component.id, kind: .minus, x: Double(minus.x), y: Double(minus.y)))
        } else if component.kind.isCurrentControlled {
            let middle = component.start + GridPoint(x: delta.x / 2, y: delta.y / 2) + side
            circuit.senses.append(SenseMarker(ownerID: component.id, kind: .current, x: Double(middle.x), y: Double(middle.y)))
        }
    }

    func addGround(at position: GridPoint) {
        guard !circuit.grounds.contains(where: { $0.position == position }) else { return }
        checkpoint()
        let ground = Ground(position: position, rotation: placementRotation)
        circuit.grounds.append(ground)
        selection = .ground(ground.id)
    }

    /// Lets components that were placed or moved replace the wires beneath them.
    private func cutWires(underComponentsIn item: Selection) {
        switch item {
        case .component(let id):
            if let component = component(id: id) { circuit.cutWires(under: component) }
        case .group(let items):
            items.forEach { cutWires(underComponentsIn: $0) }
        default:
            break
        }
    }

    /// Rotates a component 90° clockwise around its middle grid point.
    func rotateComponent(id: UUID) {
        guard let component = component(id: id) else { return }
        checkpoint()
        let delta = component.end - component.start
        // Integer division keeps the pivot on the grid for odd lengths.
        let pivot = component.start + GridPoint(x: delta.x / 2, y: delta.y / 2)
        circuit.moveComponent(
            id: id,
            start: component.start.rotatedClockwise(around: pivot),
            end: component.end.rotatedClockwise(around: pivot)
        )
        cutWires(underComponentsIn: .component(id))
    }

    func addComponent(_ kind: ComponentKind, from start: GridPoint, to end: GridPoint) {
        checkpoint()
        let component = CircuitComponent(
            kind: kind,
            start: start,
            end: end,
            name: circuit.nextName(prefix: kind.namePrefix),
            value: kind.defaultValue
        )
        circuit.components.append(component)
        if kind.isDependent { addSenseMarkers(for: component) }
        // Placed on top of a wire, the component takes the wire's place.
        circuit.cutWires(under: component)
        selection = .component(component.id)
    }

    /// Places a current arrow on the wire nearest to `point` (world points).
    /// `direction` (e.g. a drag vector) picks which way the current flows;
    /// without it the arrow points right or down.
    func addCurrentArrow(near point: CGPoint, tolerance: CGFloat, direction: CGPoint?) {
        let spacing = Self.gridSpacing
        let gridPoint = CGPoint(x: point.x / spacing, y: point.y / spacing)
        let candidates = circuit.wires.compactMap { wire in
            wire.nearest(to: gridPoint).map { (wire: wire, nearest: $0) }
        }
        guard let hit = candidates.min(by: { $0.nearest.distance < $1.nearest.distance }),
              hit.nearest.distance * spacing <= tolerance else { return }

        // Snap to half grid units along the wire so arrows line up neatly.
        let axis = hit.nearest.direction
        var anchor = hit.nearest.point
        if abs(axis.x) > abs(axis.y) {
            anchor.x = (anchor.x * 2).rounded() / 2
        } else {
            anchor.y = (anchor.y * 2).rounded() / 2
        }

        let forward: Bool
        if let direction, hypot(direction.x, direction.y) > 4 {
            forward = direction.x * axis.x + direction.y * axis.y >= 0
        } else {
            forward = axis.x + axis.y > 0
        }

        checkpoint()
        let arrow = CurrentArrow(
            wireID: hit.wire.id,
            anchorX: anchor.x,
            anchorY: anchor.y,
            forward: forward,
            name: circuit.nextName(prefix: "I"),
            value: nil
        )
        circuit.currents.append(arrow)
        selection = .currentArrow(arrow.id)
    }

    func addProbe(at position: GridPoint) {
        guard !circuit.probes.contains(where: { $0.position == position }) else { return }
        checkpoint()
        let probe = Probe(position: position, name: circuit.nextProbeName())
        circuit.probes.append(probe)
        selection = .probe(probe.id)
    }

    // MARK: Voltage drops

    /// With the voltage point tool picked with ⌘: clicks place voltage drops
    /// (V_A between a + and a − point) instead of voltage points.
    var placesVoltageDrops = false

    /// Places a voltage drop measured from `plus` to `minus`.
    func addVoltageDrop(plus: GridPoint, minus: GridPoint) {
        guard plus != minus else { return }
        checkpoint()
        var probe = Probe(position: plus, name: circuit.nextVoltageDropName())
        probe.negative = minus
        circuit.probes.append(probe)
        selection = .probe(probe.id)
    }

    /// Starts turning a voltage point into a voltage drop (⌘-drag from it):
    /// a − point appears on top of it, which `move(.probeMinus(id), by:)`
    /// then drags away. The whole thing is one undo step with the drag.
    func beginSplittingProbe(id: UUID) {
        guard let index = circuit.probes.firstIndex(where: { $0.id == id }), !circuit.probes[index].isVoltageDrop else { return }
        let before = circuit
        var split = circuit
        split.probes[index].negative = split.probes[index].position
        split.probes[index].name = split.nextVoltageDropName(excluding: id)
        split.probes[index].value = nil
        circuit = split
        moveOrigin = circuit
        moveUndoBase = before
        selection = .probeMinus(id)
    }

    /// Voltage drops whose + and − points were dragged onto each other become
    /// voltage points again.
    private func mergeCollapsedVoltageDrops() {
        let collapsed = circuit.probes.indices.filter { circuit.probes[$0].negative == circuit.probes[$0].position }
        guard !collapsed.isEmpty else { return }
        var merged = circuit
        for index in collapsed {
            merged.probes[index].negative = nil
            merged.probes[index].labelOffset = nil
            merged.probes[index].value = nil
            merged.probes[index].name = ""
            merged.probes[index].name = merged.nextProbeName()
        }
        circuit = merged
        if let selection, case .probeMinus(let id) = selection { self.selection = .probe(id) }
        if let selection, case .probeLabel(let id) = selection { self.selection = .probe(id) }
    }

    /// The state to go back to when a move that started with a split is undone.
    private var moveUndoBase: Circuit?

    /// Where a voltage drop's label is drawn (grid units): halfway between its
    /// points, moved out to the side like a controlled source's "Vs".
    func voltageDropLabelPosition(of probe: Probe) -> CGPoint? {
        guard let negative = probe.negative else { return nil }
        let a = probe.position, b = negative
        let middle = CGPoint(x: Double(a.x + b.x) / 2, y: Double(a.y + b.y) / 2)
        return abs(a.y - b.y) >= abs(a.x - b.x)
            ? CGPoint(x: middle.x + probe.labelDistance, y: middle.y)
            : CGPoint(x: middle.x, y: middle.y + probe.labelDistance)
    }

    // MARK: Equivalent resistance

    /// Handles a click with the equivalent resistance tool. The first click
    /// on the circuit picks point A, the second point B, which adds a Req
    /// between them. Clicking a Req selects it.
    func equivalentClick(at point: GridPoint, hit: Selection?) {
        if case .equivalent(let id) = hit, pendingEquivalentPoint == nil {
            selection = .equivalent(id)
            return
        }
        guard netlist.node(at: point) != nil else { return }
        guard let start = pendingEquivalentPoint else {
            pendingEquivalentPoint = point
            return
        }
        guard point != start else { return }
        checkpoint()
        let equivalent = EquivalentResistance(
            name: circuit.nextEquivalentName(),
            colorIndex: circuit.nextEquivalentColorIndex(),
            start: start,
            end: point
        )
        circuit.equivalents.append(equivalent)
        pendingEquivalentPoint = nil
        selection = .equivalent(equivalent.id)
    }

    /// Whether a click at `point` with the equivalent resistance tool would pick it.
    func isEquivalentPoint(_ point: GridPoint) -> Bool {
        netlist.node(at: point) != nil
    }

    func equivalent(id: UUID) -> EquivalentResistance? {
        circuit.equivalents.first { $0.id == id }
    }

    func updateEquivalent(id: UUID, _ change: (inout EquivalentResistance) -> Void) {
        guard let index = circuit.equivalents.firstIndex(where: { $0.id == id }) else { return }
        undoableEdit { change(&circuit.equivalents[index]) }
    }

    /// The color index of the Req a resistor is part of, if any.
    func equivalentColorIndex(ofResistor id: UUID) -> Int? {
        circuit.equivalents.first { equivalentResults[$0.id]?.resistors.contains(id) == true }?.colorIndex
    }

    // MARK: Editing

    func deleteSelection() {
        guard let selection else { return }
        checkpoint()
        delete(selection)
        self.selection = nil
    }

    // MARK: Mesh currents

    /// The direction of the next mesh current placed (R switches it).
    var meshPlacementClockwise = true

    /// Places a mesh current arrow with the next free name.
    func addMeshMarker(at position: GridPoint) {
        checkpoint()
        let marker = MeshMarker(position: position, name: circuit.nextMeshName(), clockwise: meshPlacementClockwise)
        circuit.meshMarkers.append(marker)
        selection = .meshMarker(marker.id)
    }

    // MARK: Power circles

    /// A click with the power tool: puts a power circle around the component
    /// under the point, or removes it if it's already there.
    func togglePowerCircle(near point: CGPoint, tolerance: CGFloat) {
        guard case .component(let id)? = hitTest(point, tolerance: tolerance),
              let index = circuit.components.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        circuit.components[index].showsPower = circuit.components[index].isPowerShown ? nil : true
        selection = .component(id)
    }

    /// A circle drawn with the power tool (world coordinates): every
    /// component whose middle lies inside the ellipse in `rect` gets a power circle.
    func addPowerCircles(in rect: CGRect) {
        let spacing = Self.gridSpacing
        let rx = rect.width / 2, ry = rect.height / 2
        guard rx > 0, ry > 0 else { return }
        let circled = circuit.components.indices.filter { index in
            let c = circuit.components[index]
            let mx = CGFloat(c.start.x + c.end.x) / 2 * spacing, my = CGFloat(c.start.y + c.end.y) / 2 * spacing
            let dx = (mx - rect.midX) / rx, dy = (my - rect.midY) / ry
            return dx * dx + dy * dy <= 1 && !c.isPowerShown
        }
        guard !circled.isEmpty else { return }
        checkpoint()
        for index in circled { circuit.components[index].showsPower = true }
        selection = Self.selection(of: Set(circled.map { .component(circuit.components[$0].id) }))
    }

    /// Shows or hides a component's power circle (from the inspector).
    func setPowerShown(_ shown: Bool, id: UUID) {
        guard let index = circuit.components.firstIndex(where: { $0.id == id }) else { return }
        undoableEdit { circuit.components[index].showsPower = shown ? true : nil }
    }

    func meshMarker(id: UUID) -> MeshMarker? {
        circuit.meshMarkers.first { $0.id == id }
    }

    func updateMeshMarker(id: UUID, _ change: (inout MeshMarker) -> Void) {
        guard let index = circuit.meshMarkers.firstIndex(where: { $0.id == id }) else { return }
        undoableEdit { change(&circuit.meshMarkers[index]) }
    }

    /// R: reverses a mesh current's direction.
    func flipMeshMarker(id: UUID) {
        updateMeshMarker(id: id) { $0.clockwise.toggle() }
    }

    // MARK: Excluded areas

    /// Adds a box (corners in grid points) whose contents are left out of the
    /// calculation and the Maple output.
    func addExcludedArea(from a: GridPoint, to b: GridPoint) {
        guard a.x != b.x, a.y != b.y else { return }
        checkpoint()
        let area = ExcludedArea(corner: a, corner: b)
        circuit.excludedAreas.append(area)
        selection = .excludedArea(area.id)
    }

    // MARK: Groups

    /// Adds a named, tinted group box (corners in grid points).
    func addGroupArea(from a: GridPoint, to b: GridPoint) {
        guard a.x != b.x, a.y != b.y else { return }
        checkpoint()
        let group = GroupArea(corner: a, corner: b, name: circuit.nextGroupName(), colorIndex: circuit.groupAreas.count)
        circuit.groupAreas.append(group)
        selection = .groupArea(group.id)
        tool = .select
    }

    /// Moves the edges a resize handle belongs to onto `point`, starting from
    /// the group as it was at `beginMove()`. The box keeps at least one grid
    /// unit each way.
    func resizeGroupArea(id: UUID, handle: GroupArea.Handle, to point: GridPoint) {
        guard var resized = moveOrigin, let index = resized.groupAreas.firstIndex(where: { $0.id == id }) else { return }
        var group = resized.groupAreas[index]
        if handle.x < 0 { group.from.x = min(point.x, group.to.x - 1) }
        if handle.x > 0 { group.to.x = max(point.x, group.from.x + 1) }
        if handle.y < 0 { group.from.y = min(point.y, group.to.y - 1) }
        if handle.y > 0 { group.to.y = max(point.y, group.from.y + 1) }
        resized.groupAreas[index] = group
        circuit = resized
    }

    func groupArea(id: UUID) -> GroupArea? {
        circuit.groupAreas.first { $0.id == id }
    }

    func updateGroupArea(id: UUID, _ change: (inout GroupArea) -> Void) {
        guard let index = circuit.groupAreas.firstIndex(where: { $0.id == id }) else { return }
        undoableEdit { change(&circuit.groupAreas[index]) }
    }

    /// The circuit as the calculation and the Maple output see it.
    var calculationCircuit: Circuit { circuit.excludingAreas() }

    // MARK: Freehand drawing

    /// Drawing mode: dragging on the page draws freehand lines, and the
    /// tool palette is hidden.
    var isDrawing = false {
        didSet {
            guard isDrawing, !oldValue else { return }
            finishWire()
            endTextEditing()
            pendingEquivalentPoint = nil
            selection = nil
        }
    }

    /// The pen's color (index into the pen colors) and size (index into `Stroke.widths`).
    /// Picking either switches from the eraser back to the pen.
    var penColor = 0 {
        didSet { isErasing = false }
    }
    var penSize = 1 {
        didSet { isErasing = false }
    }
    /// In drawing mode: dragging erases instead of drawing.
    var isErasing = false

    /// Starts an erasing gesture; everything it erases is undone in one step.
    func beginErasing() {
        eraseSnapshot = circuit
    }

    /// Erases the parts of freehand lines within `radius` of `point` (grid
    /// units), or with `wholeStrokes` (⌘ held) every line it touches.
    func erase(at point: CGPoint, radius: CGFloat, wholeStrokes: Bool = false) {
        erase(from: point, to: point, radius: radius, wholeStrokes: wholeStrokes)
    }

    /// Erases along the eraser's way from `start` to `end` (grid units) in
    /// one change, so a fast movement doesn't skip anything. Only lines the
    /// eraser touches are worked on.
    func erase(from start: CGPoint, to end: CGPoint, radius: CGFloat, wholeStrokes: Bool = false) {
        let steps = max(1, Int(start.distance(to: end) / (radius / 2)))
        let points = (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
        var changed = false
        var strokes: [Stroke] = []
        strokes.reserveCapacity(circuit.strokes.count)
        for stroke in circuit.strokes {
            guard stroke.touches(from: start, to: end, radius: radius) else {
                strokes.append(stroke)
                continue
            }
            changed = true
            if wholeStrokes { continue }
            var pieces = [stroke]
            for point in points {
                pieces = pieces.flatMap { $0.erasing(around: point, radius: radius) }
            }
            strokes += pieces
        }
        if changed { circuit.strokes = strokes }
    }

    func endErasing() {
        if let eraseSnapshot, eraseSnapshot != circuit { registerUndo(restoring: eraseSnapshot) }
        eraseSnapshot = nil
    }

    private var eraseSnapshot: Circuit?

    /// Adds a freehand line (points in grid units) with the current pen, as
    /// one undo step. A tap leaves a dot.
    func addStroke(_ points: [CGPoint]) {
        guard let first = points.first else { return }
        checkpoint()
        circuit.strokes.append(Stroke(points: points.count == 1 ? [first, first] : points, color: penColor, size: penSize))
    }

    // MARK: Text boxes

    /// The text box being typed in, if any.
    private(set) var editingTextBox: UUID?
    /// The size of each text box in world points, measured by the view that
    /// draws it. Used for hit testing and area selection.
    @ObservationIgnored var textBoxSizes: [UUID: CGSize] = [:]
    /// Where the tool palette lies over the sheet (in the sheet's coordinates),
    /// so scrolling there moves the palette rather than the sheet.
    @ObservationIgnored var paletteFrame: CGRect = .zero

    /// The area a text box covers, in world points.
    func textBoxRect(_ box: TextBox) -> CGRect {
        let size = textBoxSizes[box.id] ?? CGSize(width: 80, height: 24)
        let origin = CGPoint(x: CGFloat(box.position.x) * Self.gridSpacing, y: CGFloat(box.position.y) * Self.gridSpacing)
        return CGRect(origin: origin, size: size)
    }

    func textBox(id: UUID) -> TextBox? {
        circuit.textBoxes.first { $0.id == id }
    }

    /// Places a new, empty text box and starts typing in it.
    func addTextBox(at position: GridPoint) {
        endTextEditing()
        finishWire()
        beginEdit()
        let box = TextBox(position: position)
        circuit.textBoxes.append(box)
        editingTextBox = box.id
        selection = .textBox(box.id)
    }

    /// Starts typing in an existing text box.
    func beginEditingTextBox(id: UUID) {
        guard editingTextBox != id else { return }
        endTextEditing()
        beginEdit()
        editingTextBox = id
        selection = .textBox(id)
    }

    /// Stops typing. Empty lines are dropped, an empty box is removed, and
    /// everything typed becomes one undo step.
    func endTextEditing() {
        guard let id = editingTextBox else { return }
        editingTextBox = nil
        if let index = circuit.textBoxes.firstIndex(where: { $0.id == id }) {
            if circuit.textBoxes[index].isEmpty {
                circuit.textBoxes.remove(at: index)
                validateSelection()
            } else {
                circuit.textBoxes[index].lines.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            }
        }
        endEdit()
    }

    /// Changes a text box while typing; the undo step is recorded when typing ends.
    func updateTextBox(id: UUID, _ change: (inout TextBox) -> Void) {
        guard let index = circuit.textBoxes.firstIndex(where: { $0.id == id }) else { return }
        change(&circuit.textBoxes[index])
    }

    /// Values that formulas in text boxes can use, by name without "_", "{"
    /// and "}" (R_{1} → "R1"): known and, unless `includeSolved` is off,
    /// computed values of components, voltage points and currents.
    func formulaVariables(includeSolved: Bool) -> [String: Quantity] {
        let key = Self.formulaKey
        var variables: [String: Quantity] = [:]
        for component in circuit.components {
            if let value = component.value ?? (includeSolved ? solution.componentValues[component.id] : nil) {
                variables[key(component.name)] = Quantity(value, unit: PhysicalUnit(symbol: component.kind.unit))
            }
        }
        for probe in circuit.probes {
            if let value = probe.value ?? (includeSolved ? solution.probeValues[probe.id] : nil) {
                variables[key(probe.name)] = Quantity(value, unit: .volt)
            }
        }
        for arrow in circuit.currents {
            if let value = arrow.value ?? (includeSolved ? solution.currentValues[arrow.id] : nil) {
                variables[key(arrow.name)] = Quantity(value, unit: .ampere)
            }
        }
        return variables
    }

    /// A name as formulas use it: R_{1} → "R1".
    static func formulaKey(_ name: String) -> String {
        FormulaParts.key(name)
    }

    /// The unit of a component, voltage point or current named `key` in
    /// formulas, or `nil` if nothing on the sheet has that name.
    func formulaUnit(of key: String) -> String? {
        if let component = circuit.components.first(where: { Self.formulaKey($0.name) == key }) {
            return component.kind.unit
        }
        if circuit.probes.contains(where: { Self.formulaKey($0.name) == key }) { return "V" }
        if circuit.currents.contains(where: { Self.formulaKey($0.name) == key }) { return "A" }
        return nil
    }

    // MARK: Taking back a tap

    /// The editing state before a tap with a drawing tool, so the tap can be
    /// taken back when it turns out to be the first half of a double-click.
    struct TapSnapshot {
        fileprivate let circuit: Circuit
        fileprivate let routing: [GridPoint]
        fileprivate let pendingEquivalentPoint: GridPoint?
        fileprivate let selection: Selection?
    }

    func tapSnapshot() -> TapSnapshot {
        TapSnapshot(circuit: circuit, routing: routing, pendingEquivalentPoint: pendingEquivalentPoint, selection: selection)
    }

    /// Undoes whatever happened since `snapshot` was taken.
    func restore(_ snapshot: TapSnapshot) {
        if circuit != snapshot.circuit {
            // The tap recorded an undo step; undo it so it doesn't linger.
            undo()
            if circuit != snapshot.circuit { circuit = snapshot.circuit }
        }
        routing = snapshot.routing
        pendingEquivalentPoint = snapshot.pendingEquivalentPoint
        selection = snapshot.selection
    }

    // MARK: Copy and paste

    /// Items copied with ⌘C, shared by all open documents.
    private static var clipboard: Circuit?
    /// Pastes without a pointer position since the last copy, so repeated
    /// pastes don't land on top of each other.
    private var pasteCount = 0

    /// ⌘C: copies the selected items. Wire segments are copied as wires of
    /// their own; sense markers follow their source, and current arrows follow
    /// their wire.
    func copySelection() {
        finishWire()
        var copied = Circuit()
        var componentIDs = Set<UUID>()
        var wireIDs = Set<UUID>()
        var segmentsByWire: [UUID: Set<Int>] = [:]
        for item in selectedItems {
            switch item {
            case .component(let id), .senseLabel(let id): componentIDs.insert(id)
            case .wire(let id): wireIDs.insert(id)
            case .wireSegment(let id, let segment): segmentsByWire[id, default: []].insert(segment)
            case .probe(let id), .probeMinus(let id), .probeLabel(let id):
                if !copied.probes.contains(where: { $0.id == id }) { copied.probes += circuit.probes.filter { $0.id == id } }
            case .ground(let id): copied.grounds += circuit.grounds.filter { $0.id == id }
            case .equivalent(let id): copied.equivalents += circuit.equivalents.filter { $0.id == id }
            case .textBox(let id): copied.textBoxes += circuit.textBoxes.filter { $0.id == id }
            case .excludedArea(let id): copied.excludedAreas += circuit.excludedAreas.filter { $0.id == id }
            case .meshMarker(let id): copied.meshMarkers += circuit.meshMarkers.filter { $0.id == id }
            case .groupArea(let id): copied.groupAreas += circuit.groupAreas.filter { $0.id == id }
            case .sense(let id):
                if let owner = circuit.senses.first(where: { $0.id == id })?.ownerID { componentIDs.insert(owner) }
            case .currentArrow, .group: break
            }
        }
        copied.components = circuit.components.filter { componentIDs.contains($0.id) }
        copied.senses = circuit.senses.filter { componentIDs.contains($0.ownerID) }
        copied.wires = circuit.wires.filter { wireIDs.contains($0.id) }
        copied.currents = circuit.currents.filter { wireIDs.contains($0.wireID) }
        for (id, segments) in segmentsByWire where !wireIDs.contains(id) {
            guard let wire = circuit.wires.first(where: { $0.id == id }) else { continue }
            for segment in segments.sorted() where segment + 1 < wire.points.count {
                copied.wires.append(Wire(points: [wire.points[segment], wire.points[segment + 1]]))
            }
        }
        guard copied != Circuit() else { return }
        Self.clipboard = copied
        pasteCount = 0
    }

    /// ⌘V: pastes the copied items with fresh ids and free names, and selects
    /// them. With a `location` (the pointer), the items' top-left corner is
    /// placed there; otherwise each paste is shifted a bit from the original.
    func paste(at location: GridPoint? = nil) {
        guard var pasted = Self.clipboard else { return }
        finishWire()
        checkpoint()

        let offset: GridPoint
        if let location, let origin = pasted.topLeft {
            offset = location - origin
        } else {
            pasteCount += 1
            offset = GridPoint(x: 2 * pasteCount, y: 2 * pasteCount)
        }
        pasted.translate(by: offset)

        var items = Set<Selection>()
        var componentIDs: [UUID: UUID] = [:]
        var wireIDs: [UUID: UUID] = [:]
        for var component in pasted.components {
            let newID = UUID()
            componentIDs[component.id] = newID
            component.id = newID
            if circuit.isNameUsed(component.name) {
                component.name = circuit.nextName(prefix: component.kind.namePrefix)
            }
            circuit.components.append(component)
            items.insert(.component(newID))
        }
        for var marker in pasted.senses {
            guard let owner = componentIDs[marker.ownerID] else { continue }
            marker.id = UUID()
            marker.ownerID = owner
            circuit.senses.append(marker)
            items.insert(.sense(marker.id))
        }
        for var wire in pasted.wires {
            let newID = UUID()
            wireIDs[wire.id] = newID
            wire.id = newID
            circuit.wires.append(wire)
            items.insert(.wire(newID))
        }
        for var arrow in pasted.currents {
            guard let wire = wireIDs[arrow.wireID] else { continue }
            arrow.id = UUID()
            arrow.wireID = wire
            if circuit.isNameUsed(arrow.name) {
                // "I3" becomes the next free "I…".
                arrow.name = circuit.nextName(prefix: String(arrow.name.reversed().drop(while: \.isNumber).reversed()))
            }
            circuit.currents.append(arrow)
            items.insert(.currentArrow(arrow.id))
        }
        for var probe in pasted.probes {
            probe.id = UUID()
            if circuit.isNameUsed(probe.name) {
                probe.name = probe.isVoltageDrop ? circuit.nextVoltageDropName() : circuit.nextProbeName()
            }
            circuit.probes.append(probe)
            items.insert(.probe(probe.id))
        }
        for var ground in pasted.grounds {
            ground.id = UUID()
            circuit.grounds.append(ground)
            items.insert(.ground(ground.id))
        }
        for var equivalent in pasted.equivalents {
            equivalent.id = UUID()
            equivalent.name = circuit.nextEquivalentName()
            equivalent.colorIndex = circuit.nextEquivalentColorIndex()
            circuit.equivalents.append(equivalent)
            items.insert(.equivalent(equivalent.id))
        }
        for var box in pasted.textBoxes {
            box.id = UUID()
            circuit.textBoxes.append(box)
            items.insert(.textBox(box.id))
        }
        for var area in pasted.excludedAreas {
            area.id = UUID()
            circuit.excludedAreas.append(area)
            items.insert(.excludedArea(area.id))
        }
        for var marker in pasted.meshMarkers {
            marker.id = UUID()
            if circuit.meshMarkers.contains(where: { FormulaParts.key($0.name) == FormulaParts.key(marker.name) }) {
                marker.name = circuit.nextMeshName()
            }
            circuit.meshMarkers.append(marker)
            items.insert(.meshMarker(marker.id))
        }
        for var group in pasted.groupAreas {
            group.id = UUID()
            if circuit.groupAreas.contains(where: { $0.name == group.name }) { group.name = circuit.nextGroupName() }
            circuit.groupAreas.append(group)
            items.insert(.groupArea(group.id))
        }
        tool = .select
        selection = Self.selection(of: items)
    }

    private func delete(_ item: Selection) {
        switch item {
        case .component(let id):
            circuit.components.removeAll { $0.id == id }
            circuit.senses.removeAll { $0.ownerID == id }
        case .equivalent(let id):
            circuit.equivalents.removeAll { $0.id == id }
        case .wire(let id):
            circuit.wires.removeAll { $0.id == id }
            circuit.currents.removeAll { $0.wireID == id }
        case .wireSegment(let id, let segment): deleteSegments([segment], ofWire: id)
        case .probe(let id), .probeLabel(let id): circuit.probes.removeAll { $0.id == id }
        case .probeMinus(let id):
            // Without its − point, a voltage drop is a voltage point again.
            if let index = circuit.probes.firstIndex(where: { $0.id == id }) {
                circuit.probes[index].negative = nil
                circuit.probes[index].labelOffset = nil
                circuit.probes[index].value = nil
                circuit.probes[index].name = circuit.nextProbeName()
            }
        case .currentArrow(let id): circuit.currents.removeAll { $0.id == id }
        case .ground(let id): circuit.grounds.removeAll { $0.id == id }
        case .textBox(let id): circuit.textBoxes.removeAll { $0.id == id }
        case .excludedArea(let id): circuit.excludedAreas.removeAll { $0.id == id }
        case .meshMarker(let id): circuit.meshMarkers.removeAll { $0.id == id }
        case .groupArea(let id): circuit.groupAreas.removeAll { $0.id == id }
        case .sense, .senseLabel: break  // Sense markers go with their source.
        case .group(let items):
            // Segments of the same wire are removed together, since removing
            // one renumbers the others.
            var segmentsByWire: [UUID: Set<Int>] = [:]
            for item in items {
                if case .wireSegment(let id, let segment) = item {
                    segmentsByWire[id, default: []].insert(segment)
                } else {
                    delete(item)
                }
            }
            for (id, segments) in segmentsByWire {
                deleteSegments(segments, ofWire: id)
            }
        }
    }

    /// Removes segments from a wire, splitting it into the pieces that remain.
    private func deleteSegments(_ segments: Set<Int>, ofWire id: UUID) {
        guard let index = circuit.wires.firstIndex(where: { $0.id == id }) else { return }
        let wire = circuit.wires.remove(at: index)
        guard let first = wire.points.first else { return }

        var pieces: [[GridPoint]] = []
        var piece = [first]
        for segment in wire.segments.indices {
            if segments.contains(segment) {
                if piece.count >= 2 { pieces.append(piece) }
                piece = [wire.points[segment + 1]]
            } else {
                piece.append(wire.points[segment + 1])
            }
        }
        if piece.count >= 2 { pieces.append(piece) }

        // The first piece keeps the wire's id.
        let parts = pieces.enumerated().map { offset, points in
            offset == 0 ? Wire(id: wire.id, points: points) : Wire(points: points)
        }
        circuit.wires += parts

        // Current arrows move to the nearest remaining part.
        for arrowIndex in circuit.currents.indices.reversed() where circuit.currents[arrowIndex].wireID == id {
            let anchor = circuit.currents[arrowIndex].anchor
            if let part = parts.min(by: {
                ($0.nearest(to: anchor)?.distance ?? .infinity) < ($1.nearest(to: anchor)?.distance ?? .infinity)
            }) {
                circuit.currents[arrowIndex].wireID = part.id
            } else {
                circuit.currents.remove(at: arrowIndex)
            }
        }
    }

    /// Starts moving an item.
    func beginMove() {
        moveOrigin = circuit
    }

    /// Ends a move and records it as one undo step. Components dropped onto
    /// a wire replace the part of the wire beneath them.
    func endMove() {
        mergeCollapsedVoltageDrops()
        if let base = moveUndoBase ?? moveOrigin, base != circuit {
            if let movingItem { cutWires(underComponentsIn: movingItem) }
            registerUndo(restoring: base)
        }
        moveOrigin = nil
        moveUndoBase = nil
        movingItem = nil
    }

    /// Moves an item by `offset` relative to where it was at `beginMove()`.
    /// Wires attached to a moved component follow it.
    func move(_ item: Selection, by offset: GridPoint) {
        guard var moved = moveOrigin else { return }
        movingItem = item
        switch item {
        case .component(let id):
            guard let component = moved.components.first(where: { $0.id == id }) else { return }
            moved.moveComponent(id: id, start: component.start + offset, end: component.end + offset)
        case .wire(let id):
            guard let index = moved.wires.firstIndex(where: { $0.id == id }) else { return }
            moved.wires[index].points = moved.wires[index].points.map { $0 + offset }
            translateCurrents(in: &moved, by: offset) { $0.wireID == id }
        case .currentArrow(let id):
            // The arrow slides along its wire towards the pointer.
            translateCurrents(in: &moved, by: offset) { $0.id == id }
        case .wireSegment(let id, let segment):
            guard let index = moved.wires.firstIndex(where: { $0.id == id }) else { return }
            moveSegment(segment, ofWireAt: index, by: offset, in: &moved)
        case .probe(let id):
            guard let index = moved.probes.firstIndex(where: { $0.id == id }) else { return }
            moved.probes[index].position = moved.probes[index].position + offset
        case .probeMinus(let id):
            guard let index = moved.probes.firstIndex(where: { $0.id == id }) else { return }
            moved.probes[index].negative = moved.probes[index].negative.map { $0 + offset }
        case .probeLabel(let id):
            // The label stays halfway between the points; only its distance changes.
            guard let index = moved.probes.firstIndex(where: { $0.id == id }),
                  let negative = moved.probes[index].negative else { return }
            let plus = moved.probes[index].position
            let stacked = abs(plus.y - negative.y) >= abs(plus.x - negative.x)
            moved.probes[index].labelOffset = moved.probes[index].labelDistance + Double(stacked ? offset.x : offset.y)
        case .ground(let id):
            guard let ground = moved.grounds.first(where: { $0.id == id }) else { return }
            moved.moveComponents([:], grounds: [id: ground.position + offset])
        case .sense(let id):
            guard let index = moved.senses.firstIndex(where: { $0.id == id }) else { return }
            moved.senses[index].x += Double(offset.x)
            moved.senses[index].y += Double(offset.y)
        case .senseLabel(let id):
            // The label stays halfway between the points; only its distance
            // from them changes.
            guard let index = moved.components.firstIndex(where: { $0.id == id }),
                  let plus = moved.sense(of: id, .plus), let minus = moved.sense(of: id, .minus) else { return }
            if Self.sensePointsAreStacked(plus, minus) {
                moved.components[index].senseLabelOffsetX += Double(offset.x)
            } else {
                moved.components[index].senseLabelOffsetY += Double(offset.y)
            }
        case .equivalent:
            // A Req stays between its two points; it moves only along with them in a group.
            return
        case .textBox(let id):
            guard let index = moved.textBoxes.firstIndex(where: { $0.id == id }) else { return }
            moved.textBoxes[index].position = moved.textBoxes[index].position + offset
        case .meshMarker(let id):
            guard let index = moved.meshMarkers.firstIndex(where: { $0.id == id }) else { return }
            moved.meshMarkers[index].position = moved.meshMarkers[index].position + offset
        case .excludedArea(let id):
            guard let index = moved.excludedAreas.firstIndex(where: { $0.id == id }) else { return }
            moved.excludedAreas[index].from = moved.excludedAreas[index].from + offset
            moved.excludedAreas[index].to = moved.excludedAreas[index].to + offset
        case .groupArea(let id):
            guard let index = moved.groupAreas.firstIndex(where: { $0.id == id }) else { return }
            moved.groupAreas[index].from = moved.groupAreas[index].from + offset
            moved.groupAreas[index].to = moved.groupAreas[index].to + offset
        case .group(let items):
            moveGroup(items, by: offset, in: &moved)
        }
        circuit = moved
    }

    /// Moves a group together. Wires inside the group move with it, and wires
    /// from outside that are attached to its components are rubber-banded.
    private func moveGroup(_ items: Set<Selection>, by offset: GridPoint, in circuit: inout Circuit) {
        var componentTargets: [UUID: (start: GridPoint, end: GridPoint)] = [:]
        var wireIDs = Set<UUID>()
        var probeIDs = Set<UUID>()
        var arrowIDs = Set<UUID>()
        var segmentsByWire: [UUID: Set<Int>] = [:]
        var groundTargets: [UUID: GridPoint] = [:]
        var movedTerminals = Set<GridPoint>()
        for item in items {
            switch item {
            case .component(let id):
                if let component = circuit.components.first(where: { $0.id == id }) {
                    componentTargets[id] = (component.start + offset, component.end + offset)
                    movedTerminals.insert(component.start)
                    movedTerminals.insert(component.end)
                }
            case .wire(let id): wireIDs.insert(id)
            case .wireSegment(let id, let segment): segmentsByWire[id, default: []].insert(segment)
            case .probe(let id), .probeMinus(let id), .probeLabel(let id): probeIDs.insert(id)
            case .currentArrow(let id): arrowIDs.insert(id)
            case .ground(let id):
                if let ground = circuit.grounds.first(where: { $0.id == id }) {
                    groundTargets[id] = ground.position + offset
                    movedTerminals.insert(ground.position)
                }
            case .sense(let id):
                if let index = circuit.senses.firstIndex(where: { $0.id == id }) {
                    circuit.senses[index].x += Double(offset.x)
                    circuit.senses[index].y += Double(offset.y)
                }
            case .equivalent(let id):
                if let index = circuit.equivalents.firstIndex(where: { $0.id == id }) {
                    circuit.equivalents[index].start = circuit.equivalents[index].start + offset
                    circuit.equivalents[index].end = circuit.equivalents[index].end + offset
                }
            case .textBox(let id):
                if let index = circuit.textBoxes.firstIndex(where: { $0.id == id }) {
                    circuit.textBoxes[index].position = circuit.textBoxes[index].position + offset
                }
            case .meshMarker(let id):
                if let index = circuit.meshMarkers.firstIndex(where: { $0.id == id }) {
                    circuit.meshMarkers[index].position = circuit.meshMarkers[index].position + offset
                }
            case .excludedArea(let id):
                if let index = circuit.excludedAreas.firstIndex(where: { $0.id == id }) {
                    circuit.excludedAreas[index].from = circuit.excludedAreas[index].from + offset
                    circuit.excludedAreas[index].to = circuit.excludedAreas[index].to + offset
                }
            case .groupArea(let id):
                if let index = circuit.groupAreas.firstIndex(where: { $0.id == id }) {
                    circuit.groupAreas[index].from = circuit.groupAreas[index].from + offset
                    circuit.groupAreas[index].to = circuit.groupAreas[index].to + offset
                }
            case .senseLabel, .group: break
            }
        }
        translateCurrents(in: &circuit, by: offset) { arrowIDs.contains($0.id) || wireIDs.contains($0.wireID) }
        circuit.moveComponents(componentTargets, grounds: groundTargets, excludingWires: wireIDs.union(segmentsByWire.keys))
        for index in circuit.wires.indices where wireIDs.contains(circuit.wires[index].id) {
            circuit.wires[index].points = circuit.wires[index].points.map { $0 + offset }
        }
        for index in circuit.probes.indices where probeIDs.contains(circuit.probes[index].id) {
            circuit.probes[index].position = circuit.probes[index].position + offset
            circuit.probes[index].negative = circuit.probes[index].negative.map { $0 + offset }
        }

        // Selected segments move with the group; the rest of their wire stretches.
        var newItems = items.filter { if case .wireSegment = $0 { false } else { true } }
        for (id, segments) in segmentsByWire {
            guard let index = circuit.wires.firstIndex(where: { $0.id == id }) else { continue }
            let old = circuit.wires[index]
            var moving = Set<Int>()
            for segment in segments where segment + 1 < old.points.count {
                moving.insert(segment)
                moving.insert(segment + 1)
            }
            // Ends attached to a moved component come along too.
            if let first = old.points.first, movedTerminals.contains(first) { moving.insert(0) }
            if let last = old.points.last, movedTerminals.contains(last) { moving.insert(old.points.count - 1) }

            let anchors = circuit.anchorPoints(excludingWire: id)
            circuit.wires[index].points = Circuit.dragPoints(old.points, moving: moving, by: offset, anchors: anchors)
            circuit.retargetCurrents(onWire: id, from: old)

            // Corners can renumber segments; find the moved ones again.
            let new = circuit.wires[index]
            for segment in segments where segment + 1 < old.points.count {
                let a = old.points[segment] + offset
                let b = old.points[segment + 1] + offset
                if let newIndex = new.segmentIndex(containing: a, b) {
                    newItems.insert(.wireSegment(id, newIndex))
                }
            }
        }
        if !segmentsByWire.isEmpty {
            selection = Self.selection(of: newItems)
        }
    }

    /// Slides a segment sideways; the neighboring segments stretch so the wire
    /// stays connected. Ends attached to something get a new corner instead of
    /// being pulled loose.
    private func moveSegment(_ segment: Int, ofWireAt index: Int, by offset: GridPoint, in circuit: inout Circuit) {
        var points = circuit.wires[index].points
        guard segment + 1 < points.count else { return }
        let a = points[segment]
        let b = points[segment + 1]
        // A segment can only move perpendicular to its own direction.
        let delta = a.y == b.y ? GridPoint(x: 0, y: offset.y) : GridPoint(x: offset.x, y: 0)
        guard delta != GridPoint(x: 0, y: 0) else { return }

        // Arrows on the moved segment move with it.
        let wireID = circuit.wires[index].id
        let segmentStart = CGPoint(x: a.x, y: a.y)
        let segmentEnd = CGPoint(x: b.x, y: b.y)
        translateCurrents(in: &circuit, by: delta) {
            $0.wireID == wireID && $0.anchor.distance(toSegment: segmentStart, segmentEnd) < 0.01
        }

        let anchors = circuit.anchorPoints(excludingWire: circuit.wires[index].id)
        points[segment] = a + delta
        points[segment + 1] = b + delta
        if segment + 1 == points.count - 1, anchors.contains(b) {
            points.append(b)
        }
        if segment == 0, anchors.contains(a) {
            points.insert(a, at: 0)
        }
        let wire = Wire(id: circuit.wires[index].id, points: Circuit.normalized(points))
        circuit.wires[index] = wire

        // Segment indices can shift when corners are added; keep the moved one selected.
        if let newIndex = wire.segmentIndex(containing: a + delta, b + delta) {
            selection = .wireSegment(wire.id, newIndex)
        } else {
            selection = .wire(wire.id)
        }
    }

    private func translateCurrents(in circuit: inout Circuit, by offset: GridPoint, where predicate: (CurrentArrow) -> Bool) {
        for index in circuit.currents.indices where predicate(circuit.currents[index]) {
            circuit.currents[index].anchorX += Double(offset.x)
            circuit.currents[index].anchorY += Double(offset.y)
        }
    }

    /// Where a voltage-controlled source's "Vs" label is drawn (grid units):
    /// halfway between its + and − points, moved out to the side by the
    /// label's distance – sideways when the points are above each other,
    /// up or down when they're side by side.
    func senseLabelPosition(of component: CircuitComponent) -> CGPoint? {
        guard let plus = circuit.sense(of: component.id, .plus),
              let minus = circuit.sense(of: component.id, .minus) else { return nil }
        let middle = CGPoint(x: (plus.x + minus.x) / 2, y: (plus.y + minus.y) / 2)
        return Self.sensePointsAreStacked(plus, minus)
            ? CGPoint(x: middle.x + component.senseLabelOffsetX, y: middle.y)
            : CGPoint(x: middle.x, y: middle.y + component.senseLabelOffsetY)
    }

    /// Whether a source's + and − points sit more above each other than side by side.
    static func sensePointsAreStacked(_ plus: SenseMarker, _ minus: SenseMarker) -> Bool {
        abs(plus.y - minus.y) >= abs(plus.x - minus.x)
    }

    func currentArrow(id: UUID) -> CurrentArrow? {
        circuit.currents.first { $0.id == id }
    }

    func updateCurrentArrow(id: UUID, _ change: (inout CurrentArrow) -> Void) {
        guard let index = circuit.currents.firstIndex(where: { $0.id == id }) else { return }
        undoableEdit {
            var updated = circuit
            change(&updated.currents[index])
            typeIn(updated.currents[index].value, replacing: circuit.currents[index].value, of: id, in: &updated)
            circuit = updated
        }
    }

    /// Reverses the direction of a current arrow.
    func flipCurrentArrow(id: UUID) {
        updateCurrentArrow(id: id) { $0.forward.toggle() }
    }

    /// Edits made while a symbol editor is open are collected into one undo
    /// step by `endEdit()`; other edits get their own undo step.
    private func undoableEdit(_ change: () -> Void) {
        if editSnapshot == nil {
            edit(change)
        } else {
            change()
        }
    }

    func component(id: UUID) -> CircuitComponent? {
        circuit.components.first { $0.id == id }
    }

    func probe(id: UUID) -> Probe? {
        circuit.probes.first { $0.id == id }
    }

    func updateComponent(id: UUID, _ change: (inout CircuitComponent) -> Void) {
        guard let index = circuit.components.firstIndex(where: { $0.id == id }) else { return }
        undoableEdit {
            var updated = circuit
            change(&updated.components[index])
            typeIn(updated.components[index].value, replacing: circuit.components[index].value, of: id, in: &updated)
            circuit = updated
        }
    }

    func updateProbe(id: UUID, _ change: (inout Probe) -> Void) {
        guard let index = circuit.probes.firstIndex(where: { $0.id == id }) else { return }
        undoableEdit {
            var updated = circuit
            change(&updated.probes[index])
            typeIn(updated.probes[index].value, replacing: circuit.probes[index].value, of: id, in: &updated)
            circuit = updated
        }
    }

    /// A value typed in by hand is no longer inherited from a text box, so
    /// text boxes won't overwrite it. Done in the same change as the edit, so
    /// the inherited value isn't put back in between.
    private func typeIn(_ newValue: Double?, replacing oldValue: Double?, of id: UUID, in circuit: inout Circuit) {
        if newValue != oldValue { circuit.inheritedValues.remove(id) }
    }

    /// Swaps the terminals of a component, reversing a source's polarity.
    func flipComponent(id: UUID) {
        updateComponent(id: id) { swap(&$0.start, &$0.end) }
    }

    func clearAll() {
        checkpoint()
        circuit = Circuit()
        routing = []
        selection = nil
        pendingEquivalentPoint = nil
    }

    // MARK: Hit testing

    /// Finds the topmost item near a point in world coordinates.
    /// `tolerance` is given in world points.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Selection? {
        let spacing = Self.gridSpacing
        func world(_ p: GridPoint) -> CGPoint { CGPoint(x: CGFloat(p.x) * spacing, y: CGFloat(p.y) * spacing) }

        if let box = circuit.textBoxes.last(where: { textBoxRect($0).insetBy(dx: -tolerance, dy: -tolerance).contains(point) }) {
            return .textBox(box.id)
        }
        if let probe = circuit.probes.last(where: { world($0.position).distance(to: point) <= tolerance * 1.5 }) {
            return .probe(probe.id)
        }
        if let marker = circuit.meshMarkers.last(where: { world($0.position).distance(to: point) <= spacing * 1.3 }) {
            return .meshMarker(marker.id)
        }
        if let probe = circuit.probes.last(where: { probe in
            probe.negative.map { world($0).distance(to: point) <= max(tolerance * 1.5, spacing * 0.5) } ?? false
        }) {
            return .probeMinus(probe.id)
        }
        if let probe = circuit.probes.last(where: { probe in
            guard let label = voltageDropLabelPosition(of: probe) else { return false }
            return CGPoint(x: label.x * spacing, y: label.y * spacing).distance(to: point) <= spacing * 0.8
        }) {
            return .probeLabel(probe.id)
        }
        // Sense markers and "Vs" labels lie on top, so they can always be grabbed.
        if let marker = circuit.senses.last(where: {
            CGPoint(x: $0.x * spacing, y: $0.y * spacing).distance(to: point) <= max(tolerance * 1.5, spacing * 0.5)
        }) {
            return .sense(marker.id)
        }
        for component in circuit.components where component.kind.isVoltageControlled {
            if let label = senseLabelPosition(of: component),
               CGPoint(x: label.x * spacing, y: label.y * spacing).distance(to: point) <= spacing * 0.7 {
                return .senseLabel(component.id)
            }
        }
        if let ground = circuit.grounds.last(where: { ground in
            let symbolEnd = ground.position + GridPoint(x: ground.direction.x, y: ground.direction.y)
            return point.distance(toSegment: world(ground.position), world(symbolEnd)) <= max(tolerance, spacing * 0.6)
        }) {
            return .ground(ground.id)
        }
        if let arrow = circuit.currents.last(where: { arrow in
            guard let placement = circuit.placement(of: arrow) else { return false }
            let p = CGPoint(x: placement.point.x * spacing, y: placement.point.y * spacing)
            return p.distance(to: point) <= max(tolerance * 1.5, spacing * 0.5)
        }) {
            return .currentArrow(arrow.id)
        }
        if let component = circuit.components.last(where: {
            point.distance(toSegment: world($0.start), world($0.end)) <= max(tolerance, spacing * 0.7)
        }) {
            return .component(component.id)
        }
        if let equivalent = circuit.equivalents.last(where: {
            point.distance(toSegment: world($0.start), world($0.end)) <= max(tolerance, spacing * 0.7)
        }) {
            return .equivalent(equivalent.id)
        }
        for wire in circuit.wires.reversed() {
            if let segment = wire.segments.firstIndex(where: { point.distance(toSegment: world($0.0), world($0.1)) <= tolerance }) {
                return .wireSegment(wire.id, segment)
            }
        }
        // Excluded areas are grabbed by their edge, so what's inside stays clickable.
        if let area = circuit.excludedAreas.last(where: { area in
            let a = world(area.from), c = world(area.to)
            let b = CGPoint(x: c.x, y: a.y), d = CGPoint(x: a.x, y: c.y)
            return [(a, b), (b, c), (c, d), (d, a)].contains { point.distance(toSegment: $0.0, $0.1) <= max(tolerance, 4) }
        }) {
            return .excludedArea(area.id)
        }
        // Groups too, and by the name in their corner.
        if let group = circuit.groupAreas.last(where: { group in
            let a = world(group.from), c = world(group.to)
            let b = CGPoint(x: c.x, y: a.y), d = CGPoint(x: a.x, y: c.y)
            let label = CGRect(x: a.x, y: a.y, width: min(c.x - a.x, Self.groupLabelWidth(group.name)), height: spacing)
            return label.contains(point)
                || [(a, b), (b, c), (c, d), (d, a)].contains { point.distance(toSegment: $0.0, $0.1) <= max(tolerance, 4) }
        }) {
            return .groupArea(group.id)
        }
        return nil
    }

    /// Roughly how wide a group's name is on the sheet at zoom level 1.
    static func groupLabelWidth(_ name: String) -> CGFloat {
        CGFloat(name.count) * gridSpacing * 0.45 + gridSpacing
    }
}
