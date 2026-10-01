#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Observation

/// What a press, drag and release on the sheet does, independent of how the
/// sheet is drawn. Screen coordinates are in points relative to the sheet's
/// top-left corner. Shared by the web version; it follows the gestures of
/// `SchematicCanvas` so both behave the same.
@Observable
final class SheetInteraction {
    let editor: CircuitEditor

    init(editor: CircuitEditor) {
        self.editor = editor
    }

    enum DragMode {
        case idle
        /// Drawing a wire or component from `start` towards `current`.
        case drawing(start: GridPoint, current: GridPoint)
        /// Moving an existing item grabbed at grid point `origin`.
        /// `tapSelection` is applied instead if the gesture ends as a tap.
        case moving(item: Selection, origin: GridPoint, didBegin: Bool, tapSelection: Selection)
        /// Dragging out a selection rectangle, in screen coordinates.
        case selectingArea(start: CGPoint, current: CGPoint)
        /// ⌘-dragging from a voltage point: it becomes a voltage drop, and the
        /// new − point follows the pointer.
        case splittingProbe(id: UUID, origin: GridPoint, didBegin: Bool)
        /// Dragging one of the selected group's resize handles.
        case resizingGroup(id: UUID, handle: GroupArea.Handle, origin: GridPoint, didBegin: Bool)
        /// A pinch took over; ignore the rest of this drag.
        case cancelled
    }

    private(set) var dragMode: DragMode = .idle
    private(set) var hoverPoint: GridPoint?
    /// The freehand line being drawn in drawing mode, in grid units.
    private(set) var currentStroke: [CGPoint] = []
    /// The circle being drawn with the power tool, on screen.
    private(set) var powerDraft: (start: CGPoint, current: CGPoint)?
    /// Where the eraser is on screen; `nil` when not erasing.
    private(set) var eraserLocation: CGPoint?
    /// An excluded area being drawn with ⌘ + right-drag, on screen.
    private(set) var exclusionDraft: (start: CGPoint, current: CGPoint)?
    /// Whether the drawing in progress with the voltage point tool places a voltage drop.
    private(set) var placingVoltageDrop = false
    /// Whether the drag in progress with the wire tool draws a rectangle (⇧ held).
    private(set) var drawingRectangle = false
    /// Whether ⌘ (Ctrl on Windows) is held.
    var isCommandDown = false

    /// A symbol whose editor should open, and where on screen it is. Set by
    /// a double-click; the host shows the editor and clears it.
    var editRequest: (item: Selection, anchor: CGRect)?

    static let eraserRadius: CGFloat = 10

    private var isErasingDrag = false
    private var lastErasePoint: CGPoint?
    private var lastTap: (item: Selection, time: Date)?
    private var lastToolTap: (item: Selection, location: CGPoint, time: Date, before: CircuitEditor.TapSnapshot)?
    private var dragStart: CGPoint = .zero

    // MARK: Coordinates

    private var scale: CGFloat { editor.scale }
    private var offset: CGSize { editor.offset }
    private var spacing: CGFloat { CircuitEditor.gridSpacing }
    var unit: CGFloat { spacing * scale }

    func worldPoint(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - offset.width) / scale, y: (screen.y - offset.height) / scale)
    }

    func screenPoint(_ grid: GridPoint) -> CGPoint {
        CGPoint(x: CGFloat(grid.x) * spacing * scale + offset.width, y: CGFloat(grid.y) * spacing * scale + offset.height)
    }

    /// The nearest grid point, kept within the page.
    func snap(_ screen: CGPoint) -> GridPoint {
        let world = worldPoint(screen)
        return GridPoint(
            x: min(editor.pageSize.x, max(0, Int((world.x / spacing).rounded()))),
            y: min(editor.pageSize.y, max(0, Int((world.y / spacing).rounded())))
        )
    }

    /// Constrains a component to a horizontal or vertical line along the dominant drag axis.
    private func constrainedEnd(from start: GridPoint, to current: GridPoint) -> GridPoint {
        let delta = current - start
        return abs(delta.x) >= abs(delta.y)
            ? GridPoint(x: current.x, y: start.y)
            : GridPoint(x: start.x, y: current.y)
    }

    /// Terminals for a dragged component, falling back to a default-length
    /// component centered on the tap when the drag is too short.
    func componentTerminals(start: GridPoint, current: GridPoint) -> (GridPoint, GridPoint) {
        let end = constrainedEnd(from: start, to: current)
        let delta = end - start
        if abs(delta.x) + abs(delta.y) >= 2 { return (start, end) }
        return editor.defaultTerminals(centeredAt: start)
    }

    // MARK: Hover

    func hover(at location: CGPoint?) {
        guard let location else {
            hoverPoint = nil
            eraserLocation = nil
            return
        }
        hoverPoint = snap(location)
        eraserLocation = editor.isDrawing && editor.isErasing ? location : nil
    }

    // MARK: Primary button

    /// The pointer moved with the button held; `start` is where it went down.
    func drag(from start: CGPoint, to location: CGPoint, shift: Bool) {
        if editor.isDrawing {
            // Drawing mode: follow the pointer freely, without snapping.
            let world = worldPoint(location)
            let point = CGPoint(x: world.x / spacing, y: world.y / spacing)
            if editor.isErasing {
                if !isErasingDrag {
                    editor.beginErasing()
                    isErasingDrag = true
                }
                eraserLocation = location
                editor.erase(
                    from: lastErasePoint ?? point, to: point,
                    radius: Self.eraserRadius / unit, wholeStrokes: isCommandDown
                )
                lastErasePoint = point
            } else {
                currentStroke.append(point)
            }
            return
        }
        let point = snap(location)
        hoverPoint = point

        switch dragMode {
        case .idle:
            dragStart = start
            beginDrag(at: start, shift: shift)
            updateDrag(location: location, point: point)
        case .cancelled:
            break
        default:
            updateDrag(location: location, point: point)
        }
    }

    /// The button was released at `location`; `start` is where it went down.
    func endDrag(from start: CGPoint, to location: CGPoint, shift: Bool) {
        if editor.isDrawing {
            if isErasingDrag {
                editor.endErasing()
                isErasingDrag = false
                lastErasePoint = nil
            } else {
                editor.addStroke(currentStroke)
            }
            currentStroke = []
            return
        }
        // A click without movement still has to begin and end a drag.
        if case .idle = dragMode { drag(from: start, to: location, shift: shift) }
        finishDrag(start: start, location: location)
        dragMode = .idle
    }

    private func beginDrag(at location: CGPoint, shift: Bool) {
        let start = snap(location)
        // A click outside the text box being typed in ends typing.
        editor.endTextEditing()
        switch editor.tool {
        case .select:
            if !isCommandDown, let (id, handle) = groupHandle(at: location) {
                dragMode = .resizingGroup(id: id, handle: handle, origin: start, didBegin: false)
            } else if isCommandDown, case .probe(let id)? = editor.hitTest(worldPoint(location), tolerance: 8 / scale),
                      editor.probe(id: id)?.isVoltageDrop == false {
                // ⌘-drag from a voltage point pulls out a − point.
                dragMode = .splittingProbe(id: id, origin: start, didBegin: false)
            } else if let hit = editor.hitTest(worldPoint(location), tolerance: 8 / scale), isCommandDown {
                // ⌘-click toggles the item; dragging then moves the whole selection.
                editor.toggleSelection(hit)
                if let selection = editor.selection, editor.isSelected(hit) {
                    dragMode = .moving(item: selection, origin: start, didBegin: false, tapSelection: selection)
                } else {
                    dragMode = .cancelled
                }
            } else if let hit = editor.hitTest(worldPoint(location), tolerance: 8 / scale) {
                let (item, tapSelection) = selectionForHit(hit)
                editor.selection = item
                dragMode = .moving(item: item, origin: start, didBegin: false, tapSelection: tapSelection)
            } else {
                dragMode = .selectingArea(start: location, current: location)
            }
        case .text:
            if case .textBox(let id)? = editor.hitTest(worldPoint(location), tolerance: 4 / scale) {
                editor.beginEditingTextBox(id: id)
                dragMode = .cancelled
            } else {
                dragMode = .drawing(start: start, current: start)
            }
        case .probe:
            if isCommandDown, case .probe(let id)? = editor.hitTest(worldPoint(location), tolerance: 8 / scale),
               editor.probe(id: id)?.isVoltageDrop == false {
                dragMode = .splittingProbe(id: id, origin: start, didBegin: false)
            } else {
                placingVoltageDrop = editor.placesVoltageDrops || isCommandDown
                dragMode = .drawing(start: start, current: start)
            }
        case .wire:
            drawingRectangle = shift
            dragMode = .drawing(start: start, current: start)
        case .power:
            powerDraft = (location, location)
            dragMode = .drawing(start: start, current: start)
        case .component, .ground, .current, .equivalent, .mesh, .groupArea:
            dragMode = .drawing(start: start, current: start)
        }
    }

    private func updateDrag(location: CGPoint, point: GridPoint) {
        switch dragMode {
        case .drawing(let start, _):
            dragMode = .drawing(start: start, current: point)
            if let draft = powerDraft { powerDraft = (draft.start, location) }
        case .moving(let item, let origin, let didBegin, let tapSelection):
            // Don't record an undo step until the item actually moves.
            guard didBegin || point != origin else { return }
            if !didBegin {
                editor.beginMove()
                dragMode = .moving(item: item, origin: origin, didBegin: true, tapSelection: tapSelection)
            }
            editor.move(item, by: point - origin)
        case .selectingArea(let start, _):
            dragMode = .selectingArea(start: start, current: location)
        case .resizingGroup(let id, let handle, let origin, let didBegin):
            guard didBegin || point != origin else { return }
            if !didBegin {
                editor.beginMove()
                dragMode = .resizingGroup(id: id, handle: handle, origin: origin, didBegin: true)
            }
            editor.resizeGroupArea(id: id, handle: handle, to: point)
        case .splittingProbe(let id, let origin, let didBegin):
            guard didBegin || point != origin else { return }
            if !didBegin {
                editor.beginSplittingProbe(id: id)
                dragMode = .splittingProbe(id: id, origin: origin, didBegin: true)
            }
            editor.move(.probeMinus(id), by: point - origin)
        case .idle, .cancelled:
            break
        }
    }

    private func finishDrag(start startLocation: CGPoint, location: CGPoint) {
        let translation = CGPoint(x: location.x - startLocation.x, y: location.y - startLocation.y)
        let isTap = hypot(translation.x, translation.y) < 4
        switch dragMode {
        case .drawing(let start, _):
            powerDraft = nil
            if isTap, handleToolTap(at: location) { return }
            let current = snap(location)
            switch editor.tool {
            case .wire where drawingRectangle && start.x != current.x && start.y != current.y:
                editor.addRectangleWire(from: start, to: current)
            case .wire:
                // Clicks route the wire point by point. A drag works as two clicks.
                if start != current && !editor.isRouting {
                    editor.wireClick(at: start)
                }
                editor.wireClick(at: current)
            case .component(let kind):
                let (a, b) = componentTerminals(start: start, current: current)
                editor.addComponent(kind, from: a, to: b)
            case .probe:
                if placingVoltageDrop {
                    // A tap puts the − point a little below the + point.
                    editor.addVoltageDrop(plus: start, minus: start == current ? start + GridPoint(x: 0, y: 3) : current)
                } else {
                    editor.addProbe(at: current)
                }
            case .equivalent:
                editor.equivalentClick(at: current, hit: editor.hitTest(worldPoint(startLocation), tolerance: 8 / scale))
            case .ground:
                editor.addGround(at: current)
            case .text:
                editor.addTextBox(at: start)
            case .mesh:
                editor.addMeshMarker(at: current)
            case .power:
                if isTap {
                    editor.togglePowerCircle(near: worldPoint(startLocation), tolerance: 8 / scale)
                } else {
                    let a = worldPoint(startLocation), b = worldPoint(location)
                    editor.addPowerCircles(in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
                }
            case .groupArea:
                editor.addGroupArea(from: start, to: current)
            case .current:
                // Placed where the press began; a drag along the wire sets the direction.
                editor.addCurrentArrow(
                    near: worldPoint(startLocation),
                    tolerance: 12 / scale,
                    direction: isTap ? nil : translation
                )
            case .select:
                break
            }
        case .selectingArea(let start, _):
            if isTap {
                // A ⌘-click on empty space keeps the selection.
                if !isCommandDown { editor.selection = nil }
            } else {
                let a = worldPoint(start)
                let b = worldPoint(location)
                editor.selectItems(
                    in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)),
                    adding: isCommandDown
                )
            }
        case .moving(_, _, let didBegin, let tapSelection):
            if didBegin {
                editor.endMove()
            } else {
                editor.selection = tapSelection
                handleTap(on: tapSelection)
            }
        case .resizingGroup(_, _, _, let didBegin):
            if didBegin { editor.endMove() }
        case .splittingProbe(let id, _, let didBegin):
            if didBegin {
                editor.endMove()
            } else if editor.tool == .select {
                editor.toggleSelection(.probe(id))
            }
        case .idle, .cancelled:
            break
        }
    }

    /// Opens the symbol editor when the same symbol is tapped twice in quick succession.
    private func handleTap(on item: Selection) {
        let now = Date()
        if let lastTap, lastTap.item == item, now.timeIntervalSince(lastTap.time) < 0.4, isEditable(item) {
            openEditor(for: item)
            self.lastTap = nil
        } else {
            lastTap = (item, now)
        }
    }

    /// Double-clicking a symbol with a drawing tool opens its editor too. The
    /// first click has already drawn something, so it's taken back.
    private func handleToolTap(at location: CGPoint) -> Bool {
        let now = Date()
        if let lastToolTap, now.timeIntervalSince(lastToolTap.time) < 0.4,
           hypot(location.x - lastToolTap.location.x, location.y - lastToolTap.location.y) < 6 {
            self.lastToolTap = nil
            editor.restore(lastToolTap.before)
            openEditor(for: lastToolTap.item)
            return true
        }
        if let hit = editor.hitTest(worldPoint(location), tolerance: 8 / scale), isEditable(hit) {
            lastToolTap = (hit, location, now, editor.tapSnapshot())
        } else {
            lastToolTap = nil
        }
        return false
    }

    private func isEditable(_ item: Selection) -> Bool {
        if case .textBox = item { return true }
        return editorAnchor(for: item) != nil
    }

    /// Opens a symbol's editor, or starts typing in a text box.
    func openEditor(for item: Selection) {
        if case .textBox(let id) = item {
            editor.beginEditingTextBox(id: id)
        } else if let anchor = editorAnchor(for: item) {
            editor.selection = item
            // A voltage drop's markers and label all open the voltage point's editor.
            let target: Selection = switch item {
            case .probeMinus(let id), .probeLabel(let id): .probe(id)
            default: item
            }
            editRequest = (target, anchor)
        }
    }

    /// The on-screen area of a symbol that can be edited, or `nil` for other items.
    func editorAnchor(for item: Selection) -> CGRect? {
        switch item {
        case .component(let id):
            guard let component = editor.component(id: id) else { return nil }
            let a = screenPoint(component.start)
            let b = screenPoint(component.end)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                .insetBy(dx: -unit, dy: -unit)
        case .currentArrow(let id):
            guard let arrow = editor.currentArrow(id: id),
                  let placement = editor.circuit.placement(of: arrow) else { return nil }
            let p = CGPoint(x: placement.point.x * unit + offset.width, y: placement.point.y * unit + offset.height)
            return CGRect(x: p.x - unit / 2, y: p.y - unit / 2, width: unit, height: unit)
        case .probe(let id):
            guard let probe = editor.probe(id: id) else { return nil }
            let p = screenPoint(probe.position)
            return CGRect(x: p.x - unit / 2, y: p.y - unit / 2, width: unit, height: unit)
        case .probeMinus(let id):
            guard let negative = editor.probe(id: id)?.negative else { return nil }
            let p = screenPoint(negative)
            return CGRect(x: p.x - unit / 2, y: p.y - unit / 2, width: unit, height: unit)
        case .meshMarker(let id):
            guard let marker = editor.meshMarker(id: id) else { return nil }
            let p = screenPoint(marker.position)
            return CGRect(x: p.x - unit, y: p.y - unit, width: unit * 2, height: unit * 2)
        case .groupArea(let id):
            guard let group = editor.groupArea(id: id) else { return nil }
            let p = screenPoint(group.from)
            return CGRect(x: p.x, y: p.y, width: CircuitEditor.groupLabelWidth(group.name) * scale, height: unit)
        case .senseLabel(let id):
            guard let component = editor.component(id: id), let label = editor.senseLabelPosition(of: component) else { return nil }
            let p = CGPoint(x: label.x * unit + offset.width, y: label.y * unit + offset.height)
            return CGRect(x: p.x - unit, y: p.y - unit / 2, width: unit * 2, height: unit)
        case .sense(let id):
            guard let marker = editor.circuit.senses.first(where: { $0.id == id }) else { return nil }
            let p = CGPoint(x: marker.x * unit + offset.width, y: marker.y * unit + offset.height)
            return CGRect(x: p.x - unit / 2, y: p.y - unit / 2, width: unit, height: unit)
        case .probeLabel(let id):
            guard let probe = editor.probe(id: id), let label = editor.voltageDropLabelPosition(of: probe) else { return nil }
            let p = CGPoint(x: label.x * unit + offset.width, y: label.y * unit + offset.height)
            return CGRect(x: p.x - unit, y: p.y - unit / 2, width: unit * 2, height: unit)
        default:
            return nil
        }
    }

    /// Decides what a press on an item selects: the item to move if the
    /// press turns into a drag, and the selection to apply if it ends as a tap.
    private func selectionForHit(_ hit: Selection) -> (move: Selection, tap: Selection) {
        if case .wireSegment(let id, _) = hit, editor.isSelected(.wire(id)), let selection = editor.selection {
            return (selection, hit)
        }
        if case .group(let items) = editor.selection, items.contains(hit) {
            return (.group(items), hit)
        }
        return (hit, hit)
    }

    // MARK: Groups

    /// The selected group's handle under a screen point, if any.
    func groupHandle(at location: CGPoint) -> (UUID, GroupArea.Handle)? {
        guard case .groupArea(let id) = editor.selection, let group = editor.groupArea(id: id) else { return nil }
        let reach = max(9, unit * 0.45)
        let handle = GroupArea.Handle.all.min { a, b in
            handleScreenPoint(group, a).distance(to: location) < handleScreenPoint(group, b).distance(to: location)
        }
        guard let handle, handleScreenPoint(group, handle).distance(to: location) <= reach else { return nil }
        return (id, handle)
    }

    func handleScreenPoint(_ group: GroupArea, _ handle: GroupArea.Handle) -> CGPoint {
        let p = group.position(of: handle)
        return CGPoint(x: p.x * unit + offset.width, y: p.y * unit + offset.height)
    }

    // MARK: Secondary button and panning

    /// Right-drag pans; with ⌘ held it draws an excluded area instead.
    func beginRightDrag(at location: CGPoint) {
        cancelDrag()
        if isCommandDown { exclusionDraft = (location, location) }
    }

    func rightDrag(by delta: CGSize) {
        guard let draft = exclusionDraft else {
            pan(by: delta)
            return
        }
        exclusionDraft = (draft.start, CGPoint(x: draft.current.x + delta.width, y: draft.current.y + delta.height))
    }

    func endRightDrag() {
        guard let draft = exclusionDraft else { return }
        exclusionDraft = nil
        editor.addExcludedArea(from: snap(draft.start), to: snap(draft.current))
    }

    func pan(by delta: CGSize) {
        editor.setOffset(CGSize(width: offset.width + delta.width, height: offset.height + delta.height))
    }

    /// A pan or pinch takes over from a drawing or area selection in progress.
    func cancelDrag() {
        currentStroke = []
        powerDraft = nil
        if case .splittingProbe(_, _, true) = dragMode {
            editor.endMove()
            dragMode = .cancelled
        }
        if case .resizingGroup(_, _, _, true) = dragMode {
            editor.endMove()
            dragMode = .cancelled
        }
        if isErasingDrag {
            editor.endErasing()
            isErasingDrag = false
            lastErasePoint = nil
        }
        switch dragMode {
        case .drawing, .selectingArea: dragMode = .cancelled
        default: break
        }
    }

    /// Forgets a drag in progress, e.g. when the tool changes.
    func resetDrag() {
        dragMode = .idle
    }
}
