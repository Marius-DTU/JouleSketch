import SwiftUI

/// The moments a signal generator changes something on the sheet (an LED
/// blinking, a value shown as it is right now), so it's redrawn then and
/// not every frame. Just once when nothing changes over time.
struct SignalSchedule: TimelineSchedule {
    let solution: CircuitSolution
    /// Whether a value is shown as it is right now, changing smoothly.
    var continuous = false

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            // A moment after the change, so the new piece of the period is drawn.
            next = solution.nextRedraw(after: current.timeIntervalSinceReferenceDate, continuous: continuous)
                .map { Date(timeIntervalSinceReferenceDate: $0 + 0.001) }
            return current
        }
    }
}

/// The dotted drawing sheet. Handles rendering, snapping, drawing, moving,
/// panning and zooming.
struct SchematicCanvas: View {
    let editor: CircuitEditor

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SettingsKey.background) private var background = CanvasBackground.paper
    @AppStorage(SettingsKey.customBackground) private var customBackground = ""
    @AppStorage(SettingsKey.showGrid) private var showGrid = true
    @AppStorage(SettingsKey.resistorStyle) private var resistorStyle = ResistorStyle.iec
    @AppStorage(SettingsKey.keyBindings) private var keyBindingsStorage = ""
    @AppStorage(SettingsKey.pageWidth) private var pageWidth = PageSize.defaultWidth
    @AppStorage(SettingsKey.pageHeight) private var pageHeight = PageSize.defaultHeight
    @AppStorage(SettingsKey.studyMode) private var studyMode = false

    /// The computed values to show; none in study mode.
    private var solution: CircuitSolution { frameSolution ?? (studyMode ? editor.solution.withoutValues : editor.solution) }
    /// The values as they are in the frame being drawn (`at(_:)`), set on
    /// the copy of the view that draws it.
    private var frameSolution: CircuitSolution?
    /// The time of the frame being drawn (seconds), for values shown as they
    /// are right now.
    private var frameTime: Double = 0

    @State private var hoverPoint: GridPoint?
    /// Where the pointer is on screen, unsnapped.
    @State private var hoverLocation: CGPoint?
    @State private var dragMode: DragMode = .idle
    /// The freehand line being drawn in drawing mode, in grid units.
    @State private var currentStroke: [CGPoint] = []
    /// The circle being drawn with the power tool: where the drag began and
    /// where it is now, on screen.
    @State private var powerDraft: (start: CGPoint, current: CGPoint)?
    /// Where the eraser is on screen, to draw its outline; `nil` when not erasing.
    @State private var eraserLocation: CGPoint?
    /// Whether an erasing drag has begun (and been given its undo step).
    @State private var isErasingDrag = false
    /// Where the eraser was at the previous drag event, in grid units.
    @State private var lastErasePoint: CGPoint?
    /// The eraser's radius on screen, in points.
    private static let eraserRadius: CGFloat = 10
    @State private var magnifyStart: (scale: CGFloat, offset: CGSize)?
    /// The canvas takes keyboard focus when clicked, so R and Esc reach it
    /// but don't interfere with typing in the inspector.
    @FocusState private var isFocused: Bool

    /// Whether ⌘ is held; ⌘-click adds to or removes from the selection.
    /// Tracked on macOS 15 and later; older systems read the keyboard directly.
    @State private var trackedCommandDown = false
    private var isCommandDown: Bool {
        get {
            #if os(macOS)
            if #unavailable(macOS 15.0) {
                return NSEvent.modifierFlags.contains(.command)
            }
            #endif
            return trackedCommandDown
        }
        nonmutating set { trackedCommandDown = newValue }
    }

    /// The last tap on an item, used to detect double-clicks.
    @State private var lastTap: (item: Selection, time: Date)?
    /// The symbol whose editor popover is open.
    @State private var editTarget: SymbolEditTarget?
    /// The last tap with a drawing tool on an editable symbol, and the state
    /// before it, so a double-click can take the tap back and open the editor.
    /// Whether the drawing in progress with the voltage point tool places a
    /// voltage drop (tool picked with ⌘, or ⌘ held when the drag began).
    @State private var placingVoltageDrop = false
    /// Whether the drag in progress with the wire tool draws a rectangle (⇧ held).
    @State private var drawingRectangle = false
    /// An excluded area being drawn with ⌘ + right-drag, in screen coordinates.
    @State private var exclusionDraft: (start: CGPoint, current: CGPoint)?
    @State private var lastToolTap: (item: Selection, location: CGPoint, time: Date, before: CircuitEditor.TapSnapshot)?

    private enum DragMode {
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

    /// Zoom factor and pan offset: screen = world * scale + offset.
    private var scale: CGFloat {
        get { editor.scale }
        nonmutating set { editor.scale = newValue }
    }
    private var offset: CGSize {
        get { editor.offset }
        nonmutating set { editor.setOffset(newValue) }
    }

    private var spacing: CGFloat { CircuitEditor.gridSpacing }
    private var unit: CGFloat { spacing * scale }
    private var theme: SchematicTheme {
        SchematicTheme(
            background: background,
            customColor: Color.Resolved(storageString: customBackground) ?? .defaultCustomBackground,
            colorScheme: colorScheme
        )
    }

    var body: some View {
        // Redrawn only when a signal generator changes something on the sheet.
        TimelineView(SignalSchedule(solution: editor.solution, continuous: editor.hasContinuousMeasurement)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                var frame = self
                frame.frameSolution = solution.at(time)
                frame.frameTime = time
                frame.drawPage(in: context, size: size)
                if showGrid { frame.drawGrid(in: context, size: size) }
                frame.drawGroupAreas(in: context)
                frame.drawCircuit(in: context, time: time)
                frame.drawExcludedAreas(in: context)
                frame.drawGroupHandles(in: context)
                frame.drawStrokes(in: context)
                frame.drawEraser(in: context)
                frame.drawPreview(in: context)
                frame.drawSelectionRect(in: context)
                frame.drawCrosshair(in: context, size: size)
            }
        }
        .background(theme.sheet)
        #if os(macOS)
        // Two-finger scrolling on the trackpad moves the view.
        .background { ScrollWheelPanner(onScroll: pan, passesThrough: { editor.paletteFrame.contains($0) }) }
        #endif
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        // Right-drag pans; with ⌘ held it draws an excluded area instead.
        .panGesture(PanRecognizer(input: .secondaryButton, onBegan: beginRightDrag, onChanged: rightDrag, onEnded: endRightDrag))
        // A right-click on a symbol opens its editor, like a double-click.
        .secondaryClickGesture(SecondaryClickRecognizer(onClick: rightClick))
        #if os(iOS)
        .panGesture(PanRecognizer(input: .twoFingers, onBegan: { _ in cancelDrag() }, onChanged: pan))
        #endif
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverPoint = snap(location)
                hoverLocation = location
                eraserLocation = editor.isDrawing && editor.isErasing ? location : nil
            case .ended:
                hoverPoint = nil
                hoverLocation = nil
                eraserLocation = nil
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            handleKey(press)
        }
        #if os(macOS)
        .onCommandKeyChanged { isCommandDown = $0 }
        // Enables Edit › Select All (⌘A) in the menu bar while the sheet is focused.
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            editor.selectAll()
        }
        // Edit › Copy (⌘C) and Paste (⌘V).
        .onCommand(#selector(NSText.copy(_:))) {
            editor.copySelection()
        }
        .onCommand(#selector(NSText.paste(_:))) {
            editor.paste(at: hoverPoint)
        }
        #endif
        .onKeyPress(.escape) {
            editor.escape()
            return .handled
        }
        #if os(macOS)
        // Backspace and forward delete arrive as the system Delete command on Mac.
        .onDeleteCommand {
            editor.deleteSelection()
        }
        #else
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            editor.deleteSelection()
            return .handled
        }
        #endif
        .popover(item: $editTarget, attachmentAnchor: .rect(.rect(editTarget?.anchor ?? .zero))) { target in
            SymbolEditorView(editor: editor, item: target.item)
        }
        .onChange(of: editTarget == nil) {
            // Give keyboard focus back to the canvas when the editor closes.
            if editTarget == nil { isFocused = true }
        }
        .onAppear {
            isFocused = true
            editor.pageSize = GridPoint(x: pageWidth, y: pageHeight)
        }
        // The editor keeps the middle of the screen on the page.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { editor.viewSize = $0 }
        .onChange(of: pageWidth) { editor.pageSize = GridPoint(x: pageWidth, y: pageHeight) }
        .onChange(of: pageHeight) { editor.pageSize = GridPoint(x: pageWidth, y: pageHeight) }
        .onChange(of: editor.tool) {
            dragMode = .idle
        }
        // Text boxes lie on top of the drawing, outside its gestures, so the
        // one being typed in gets its clicks and keys.
        .overlay(alignment: .topLeading) { textBoxLayer }
        .onChange(of: editor.editingTextBox == nil) {
            // Give keyboard focus back to the canvas when typing ends.
            if editor.editingTextBox == nil { isFocused = true }
        }
    }

    // MARK: - Text boxes

    private var textBoxLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(editor.circuit.textBoxes) { box in
                let isEditing = editor.editingTextBox == box.id
                TextBoxView(
                    editor: editor,
                    box: box,
                    isEditing: isEditing,
                    isSelected: editor.isSelected(.textBox(box.id)),
                    textColor: theme.label,
                    background: theme.sheet
                )
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: CGFloat(box.position.x) * unit + offset.width, y: CGFloat(box.position.y) * unit + offset.height)
                // Only the box being typed in takes clicks; the others are
                // selected and moved through the canvas like other items.
                .allowsHitTesting(isEditing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    // MARK: - Keyboard

    /// Single-key shortcuts: R rotates, and each tool has its own key.
    /// Keys with ⌘, ⌃ or ⌥ are left for menu shortcuts such as ⌘Z.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // ⌘A selects everything (on Mac the Edit menu normally handles it first).
        if press.modifiers == .command, press.characters.lowercased() == "a" {
            editor.selectAll()
            return .handled
        }
        // ⌘C copies the selection, ⌘V pastes it at the pointer.
        if press.modifiers == .command, press.characters.lowercased() == "c" {
            editor.copySelection()
            return .handled
        }
        if press.modifiers == .command, press.characters.lowercased() == "v" {
            editor.paste(at: hoverPoint)
            return .handled
        }
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        guard let action = KeyBindings(storageString: keyBindingsStorage).action(for: press.characters, mode: editor.sheetMode) else {
            return .ignored
        }
        switch action {
        case .rotate: editor.rotate()
        case .selectWholeWire: editor.selectWholeWires()
        case .leaveBlock: editor.leaveBlock()
        default:
            if let tool = action.tool { editor.tool = tool }
        }
        return .handled
    }

    // MARK: - Panning

    private func beginRightDrag(at location: CGPoint) {
        cancelDrag()
        if isCommandDown { exclusionDraft = (location, location) }
    }

    private func rightDrag(by delta: CGSize) {
        guard let draft = exclusionDraft else {
            pan(by: delta)
            return
        }
        exclusionDraft = (draft.start, CGPoint(x: draft.current.x + delta.width, y: draft.current.y + delta.height))
    }

    private func endRightDrag() {
        guard let draft = exclusionDraft else { return }
        exclusionDraft = nil
        editor.addExcludedArea(from: snap(draft.start), to: snap(draft.current))
    }

    /// Opens the editor of the symbol under a right-click, if it has one.
    private func rightClick(at location: CGPoint) {
        guard let hit = editor.hitTest(worldPoint(location), tolerance: 8 / scale), isEditable(hit) else { return }
        openEditor(for: hit)
    }

    private func pan(by delta: CGSize) {
        offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
    }

    /// A pan or pinch takes over from a drawing or area selection in progress.
    private func cancelDrag() {
        currentStroke = []
        powerDraft = nil
        editor.releaseButtons()
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

    // MARK: - Coordinate conversion

    private func worldPoint(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - offset.width) / scale, y: (screen.y - offset.height) / scale)
    }

    private func screenPoint(_ grid: GridPoint) -> CGPoint {
        CGPoint(
            x: CGFloat(grid.x) * spacing * scale + offset.width,
            y: CGFloat(grid.y) * spacing * scale + offset.height
        )
    }

    /// The nearest grid point, kept within the page.
    private func snap(_ screen: CGPoint) -> GridPoint {
        let world = worldPoint(screen)
        return GridPoint(
            x: min(pageWidth, max(0, Int((world.x / spacing).rounded()))),
            y: min(pageHeight, max(0, Int((world.y / spacing).rounded())))
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
    private func componentTerminals(start: GridPoint, current: GridPoint) -> (GridPoint, GridPoint) {
        let end = constrainedEnd(from: start, to: current)
        let delta = end - start
        if abs(delta.x) + abs(delta.y) >= 2 { return (start, end) }
        return editor.defaultTerminals(centeredAt: start)
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isFocused = true
                if editor.isDrawing {
                    // Drawing mode: follow the pointer freely, without snapping.
                    let world = worldPoint(value.location)
                    let point = CGPoint(x: world.x / spacing, y: world.y / spacing)
                    if editor.isErasing {
                        if !isErasingDrag {
                            editor.beginErasing()
                            isErasingDrag = true
                        }
                        eraserLocation = value.location
                        // Erase along the way from the previous event too, so
                        // a fast movement doesn't skip pieces. With ⌘ held,
                        // whole lines go at once.
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
                let point = snap(value.location)
                hoverPoint = point

                switch dragMode {
                case .idle:
                    beginDrag(at: value.startLocation)
                    updateDrag(value, point: point)
                case .cancelled:
                    break
                default:
                    updateDrag(value, point: point)
                }
            }
            .onEnded { value in
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
                endDrag(value)
                dragMode = .idle
                #if os(iOS)
                // A finger doesn't hover, so the crosshair goes when it lifts.
                hoverPoint = nil
                #endif
            }
    }

    private func beginDrag(at location: CGPoint) {
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
                // A push button is closed while it's held down.
                if let button = editor.switchComponent(hit), button.kind == .pushButton { editor.pressButton(id: button.id) }
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
            drawingRectangle = Self.isShiftHeld
            dragMode = .drawing(start: start, current: start)
        case .power:
            powerDraft = (location, location)
            dragMode = .drawing(start: start, current: start)
        case .component, .ground, .current, .equivalent, .mesh, .groupArea, .gate, .invert:
            dragMode = .drawing(start: start, current: start)
        }
    }

    /// Whether ⇧ is held right now (Mac only).
    private static var isShiftHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    private func updateDrag(_ value: DragGesture.Value, point: GridPoint) {
        switch dragMode {
        case .drawing(let start, _):
            dragMode = .drawing(start: start, current: point)
            if let draft = powerDraft { powerDraft = (draft.start, value.location) }
        case .moving(let item, let origin, let didBegin, let tapSelection):
            // Don't record an undo step until the item actually moves.
            guard didBegin || point != origin else { return }
            if !didBegin {
                editor.beginMove()
                dragMode = .moving(item: item, origin: origin, didBegin: true, tapSelection: tapSelection)
            }
            editor.move(item, by: point - origin)
        case .selectingArea(let start, _):
            dragMode = .selectingArea(start: start, current: value.location)
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

    private func endDrag(_ value: DragGesture.Value) {
        let isTap = hypot(value.translation.width, value.translation.height) < 4
        switch dragMode {
        case .drawing(let start, _):
            powerDraft = nil
            if isTap, handleToolTap(at: value.location) { return }
            let current = snap(value.location)
            switch editor.tool {
            case .wire where drawingRectangle && start.x != current.x && start.y != current.y:
                editor.addRectangleWire(from: start, to: current)
            case .wire:
                // Clicks route the wire point by point. A drag works as two
                // clicks (start and end), so touch screens without hover can
                // still see where the next segment goes.
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
                editor.equivalentClick(at: current, hit: editor.hitTest(worldPoint(value.startLocation), tolerance: 8 / scale))
            case .ground:
                editor.addGround(at: current)
            case .gate(let kind):
                editor.addGate(kind, at: current)
            case .invert:
                editor.toggleInversion(near: worldPoint(value.startLocation), tolerance: 12 / scale)
            case .text:
                editor.addTextBox(at: start)
            case .mesh:
                editor.addMeshMarker(at: current)
            case .power:
                if isTap {
                    editor.togglePowerCircle(near: worldPoint(value.startLocation), tolerance: 8 / scale)
                } else {
                    let a = worldPoint(value.startLocation), b = worldPoint(value.location)
                    editor.addPowerCircles(in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
                }
            case .groupArea:
                editor.addGroupArea(from: start, to: current)
            case .current:
                // Placed where the press began; a drag along the wire sets the direction.
                editor.addCurrentArrow(
                    near: worldPoint(value.startLocation),
                    tolerance: 12 / scale,
                    direction: isTap ? nil : CGPoint(x: value.translation.width, y: value.translation.height)
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
                let b = worldPoint(value.location)
                editor.selectItems(
                    in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)),
                    adding: isCommandDown
                )
            }
        case .moving(_, _, let didBegin, let tapSelection):
            editor.releaseButtons()
            if didBegin {
                editor.endMove()
            } else {
                editor.selection = tapSelection
                // Clicking a switch opens or closes it.
                if let toggle = editor.switchComponent(tapSelection), toggle.kind == .toggleSwitch {
                    editor.toggleSwitch(id: toggle.id)
                }
                // Clicking an input switches it between 0 and 1.
                if let input = editor.logicInput(tapSelection) {
                    editor.toggleInput(id: input.id)
                }
                handleTap(on: tapSelection)
            }
        case .resizingGroup(_, _, _, let didBegin):
            if didBegin { editor.endMove() }
        case .splittingProbe(let id, _, let didBegin):
            if didBegin {
                editor.endMove()
            } else if editor.tool == .select {
                // A ⌘-click without dragging adds or removes it from the selection.
                editor.toggleSelection(.probe(id))
            }
        case .idle, .cancelled:
            break
        }
    }

    /// Opens the symbol editor when the same symbol is tapped twice in quick succession.
    /// A double-click opens the item's editor, or goes into a block's
    /// sub-diagram (its editor is opened with a right-click).
    private func handleTap(on item: Selection) {
        let now = Date()
        if let lastTap, lastTap.item == item, now.timeIntervalSince(lastTap.time) < 0.4, isEditable(item) {
            if !editor.enterIfBlock(item) { openEditor(for: item) }
            self.lastTap = nil
        } else {
            lastTap = (item, now)
        }
    }

    /// Double-clicking a symbol with a drawing tool opens its editor too. The
    /// first click has already drawn something, so it's taken back. Returns
    /// `true` when the tap opened the editor and shouldn't draw.
    private func handleToolTap(at location: CGPoint) -> Bool {
        let now = Date()
        if let lastToolTap, now.timeIntervalSince(lastToolTap.time) < 0.4,
           hypot(location.x - lastToolTap.location.x, location.y - lastToolTap.location.y) < 6 {
            self.lastToolTap = nil
            editor.restore(lastToolTap.before)
            if !editor.enterIfBlock(lastToolTap.item) { openEditor(for: lastToolTap.item) }
            return true
        }
        // Remember taps on editable symbols (before this tap draws anything).
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
    private func openEditor(for item: Selection) {
        if case .textBox(let id) = item {
            editor.beginEditingTextBox(id: id)
        } else if let anchor = editorAnchor(for: item) {
            editor.selection = item
            // A voltage drop's markers and label all open the voltage point's editor.
            let target: Selection = switch item {
            case .probeMinus(let id), .probeLabel(let id): .probe(id)
            default: item
            }
            editTarget = SymbolEditTarget(item: target, anchor: anchor)
        }
    }

    /// The on-screen area of a symbol that can be edited, or `nil` for other items.
    private func editorAnchor(for item: Selection) -> CGRect? {
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
            // The name in the corner.
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
        case .gate(let id):
            guard let gate = editor.gate(id: id) else { return nil }
            let bounds = gate.bounds
            return CGRect(x: bounds.minX * unit + offset.width, y: bounds.minY * unit + offset.height, width: bounds.width * unit, height: bounds.height * unit)
        default:
            return nil
        }
    }

    /// Decides what a press on an item selects. A wire press selects the
    /// segment under the pointer (U extends it to the whole wire).
    /// Returns the item to move if the press turns into a drag, and the
    /// selection to apply if it ends as a tap.
    private func selectionForHit(_ hit: Selection) -> (move: Selection, tap: Selection) {
        // Pressing on a selected item moves the whole selection (a group or a
        // whole wire); a tap then selects just what was pressed.
        if case .wireSegment(let id, _) = hit, editor.isSelected(.wire(id)), let selection = editor.selection {
            return (selection, hit)
        }
        if case .group(let items) = editor.selection, items.contains(hit) {
            return (.group(items), hit)
        }
        return (hit, hit)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyStart == nil {
                    magnifyStart = (scale, offset)
                    // A pinch cancels any drawing that the first finger started.
                    cancelDrag()
                }
                guard let start = magnifyStart else { return }
                let newScale = min(4, max(0.25, start.scale * value.magnification))
                // Keep the world point under the pinch anchor fixed on screen.
                let anchor = value.startLocation
                let world = CGPoint(
                    x: (anchor.x - start.offset.width) / start.scale,
                    y: (anchor.y - start.offset.height) / start.scale
                )
                scale = newScale
                offset = CGSize(width: anchor.x - world.x * newScale, height: anchor.y - world.y * newScale)
            }
            .onEnded { _ in
                magnifyStart = nil
            }
    }

    // MARK: - Drawing

    /// Shades the area outside the page and outlines the page edge.
    private func drawPage(in context: GraphicsContext, size: CGSize) {
        let a = screenPoint(GridPoint(x: 0, y: 0))
        let b = screenPoint(GridPoint(x: pageWidth, y: pageHeight))
        let page = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        var outside = Path(CGRect(origin: .zero, size: size))
        outside.addRect(page)
        context.fill(outside, with: .color(theme.outsidePage), style: FillStyle(eoFill: true))
        context.stroke(Path(page), with: .color(theme.gridMajor), lineWidth: 1)
    }

    private func drawGrid(in context: GraphicsContext, size: CGSize) {
        // Skip dots when zoomed far out so the sheet doesn't turn grey.
        var step = 1
        while unit * CGFloat(step) < 10 { step *= 2 }

        let topLeft = worldPoint(.zero)
        let bottomRight = worldPoint(CGPoint(x: size.width, y: size.height))
        // Only the visible part of the page gets dots.
        let minX = max(0, Int((topLeft.x / spacing).rounded(.down)) / step * step - step)
        let maxX = min(pageWidth, Int((bottomRight.x / spacing).rounded(.up)))
        let minY = max(0, Int((topLeft.y / spacing).rounded(.down)) / step * step - step)
        let maxY = min(pageHeight, Int((bottomRight.y / spacing).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }

        var minor = Path()
        var major = Path()
        let minorSize: CGFloat = 1.5
        let majorSize: CGFloat = 2.5
        for gx in stride(from: minX, through: maxX, by: step) {
            for gy in stride(from: minY, through: maxY, by: step) {
                let p = screenPoint(GridPoint(x: gx, y: gy))
                if gx % 10 == 0 || gy % 10 == 0 {
                    major.addRect(CGRect(x: p.x - majorSize / 2, y: p.y - majorSize / 2, width: majorSize, height: majorSize))
                } else {
                    minor.addRect(CGRect(x: p.x - minorSize / 2, y: p.y - minorSize / 2, width: minorSize, height: minorSize))
                }
            }
        }
        context.fill(minor, with: .color(theme.gridMinor))
        context.fill(major, with: .color(theme.gridMajor))
    }

    /// `time` is in seconds, for LEDs blinking with a signal generator.
    private func drawCircuit(in context: GraphicsContext, time: Double) {
        let circuit = editor.circuit
        let lineWidth = max(1, 2 * scale)

        for wire in circuit.wires {
            var path = Path()
            path.addLines(wire.points.map(screenPoint))
            // On a digital sheet, wires carrying a 1 light up.
            let color = editor.isSelected(.wire(wire.id)) ? theme.selection : editor.isWireHigh(wire) == true ? theme.logicHigh : theme.wire
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            for (index, segment) in wire.segments.enumerated() where editor.isSelected(.wireSegment(wire.id, index)) {
                var highlight = Path()
                highlight.move(to: screenPoint(segment.0))
                highlight.addLine(to: screenPoint(segment.1))
                context.stroke(highlight, with: .color(theme.selection), style: StrokeStyle(lineWidth: lineWidth * 1.5, lineCap: .round))
            }
        }

        for component in circuit.components {
            let isSelected = editor.isSelected(.component(component.id))
            // Resistors in a Req keep the Req's color.
            let groupColor = editor.equivalentColorIndex(ofResistor: component.id).map(theme.groupColor)
            drawComponent(component, color: isSelected ? theme.selection : groupColor ?? theme.component, time: time, in: context)
        }

        for component in circuit.components where component.isPowerShown {
            drawPowerCircle(around: component, in: context)
        }

        for equivalent in circuit.equivalents {
            drawEquivalent(equivalent, in: context)
        }

        for ground in circuit.grounds {
            let color = editor.isSelected(.ground(ground.id)) ? theme.selection : theme.component
            drawGround(at: ground.position, rotation: ground.rotation, color: color, in: context)
        }

        for gate in circuit.gates {
            let scene = theme.scene
            let color = editor.isSelected(.gate(gate.id)) ? scene.selection : scene.component
            drawGate(gate, color: color, value: gate.kind.isGate ? nil : editor.logicValue(of: gate), in: context)
        }

        let dotRadius = max(2.5, unit * 0.2)
        for junction in circuit.junctions {
            let p = screenPoint(junction)
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - dotRadius, y: p.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
                with: .color(theme.wire)
            )
        }

        for arrow in circuit.currents {
            guard let placement = circuit.placement(of: arrow) else { continue }
            let point = CGPoint(x: placement.point.x * unit + offset.width, y: placement.point.y * unit + offset.height)
            let color = editor.isSelected(.currentArrow(arrow.id)) ? theme.selection : theme.current
            drawCurrentArrow(arrow, at: point, direction: placement.direction, color: color, in: context)
        }

        drawSenseMarkers(in: context)

        for marker in circuit.meshMarkers {
            let color = editor.isSelected(.meshMarker(marker.id)) ? theme.selection : theme.current
            drawMeshMarker(at: screenPoint(marker.position), name: marker.name, clockwise: marker.clockwise, color: color, in: context)
        }

        for probe in circuit.probes where probe.isVoltageDrop {
            drawVoltageDrop(probe, in: context)
        }
        for probe in circuit.probes where !probe.isVoltageDrop {
            let color = editor.isSelected(.probe(probe.id)) ? theme.selection : theme.probe
            let point = screenPoint(probe.position)
            SymbolRenderer.drawProbe(at: point, unit: unit, color: color, in: context)
            drawValueLabel(
                name: probe.name, value: probe.value, measured: solution.measurementText(probe.id, mode: probe.measure, unit: "V", at: frameTime),
                unit: "V", color: color, in: context
            ) { text in
                context.draw(text, at: CGPoint(x: point.x + unit * 0.5, y: point.y - unit * 0.45), anchor: .bottomLeading)
            }
        }
    }

    private func drawComponent(_ component: CircuitComponent, color: Color, time: Double, in context: GraphicsContext) {
        let a = screenPoint(component.start)
        let b = screenPoint(component.end)
        SymbolRenderer.drawComponent(
            component.kind, from: a, to: b, unit: unit, color: color,
            lineWidth: max(1, 2 * scale), resistorStyle: resistorStyle,
            // A conducting LED is drawn lit, blinking with a signal generator.
            brightness: component.kind == .led ? solution.ledBrightness(component.id, at: time) : 0,
            light: SymbolRenderer.light(component.ledColor),
            waveform: component.signalWaveform,
            isClosed: editor.isClosed(component),
            isNormallyClosed: component.isNormallyClosed,
            in: context
        )

        // Name and value labels beside the symbol body.
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let size = max(7, unit * 0.6)
        let font = Font.system(size: size, weight: .medium)
        let name = subscriptedName(component.name, font: font, size: size, weight: .medium, color: theme.label)
        // A value the calculation filled in is shown in grey italics.
        // A value given by a "!name := …" line in a text box is shown in purple.
        var value: Text = if component.value == nil, let computed = solution.componentValues[component.id] {
            Text(gainOrValue(computed, of: component)).font(font.italic()).foregroundStyle(theme.computed)
        } else {
            Text(component.value.map { gainOrValue($0, of: component) } ?? (component.kind.isDependent ? "?" : SIValue.format(nil, unit: component.kind.unit)))
                .font(font).foregroundStyle(editor.isInherited(component.name) ? theme.inherited : theme.label)
        }
        // Controlled sources show their gain times the controlling quantity, e.g. "2 · VA".
        if component.kind.isDependent {
            let control = subscriptedName(component.controlLabel, font: font, size: size, weight: .medium, color: theme.label)
            value = Text("\(value)\(Text(" · ").font(font).foregroundStyle(theme.label))\(control)")
        }
        // Signal generators show their phase, duty cycle and frequency, e.g.
        // "5 V, 10 %, 1 kHz"; a low-side output only "10 %, 1 kHz".
        if component.isLowSideOutput, let label = component.signalLabel(valueText: "") {
            value = Text(label).font(font).foregroundStyle(theme.label)
        } else if let details = component.signalDetails {
            value = Text("\(value)\(Text(details).font(font).foregroundStyle(theme.label))")
        }
        // Switches have no value, only their name.
        if component.kind.isSwitch {
            value = Text(component.isNormallyClosed ? "NC" : "").font(font).foregroundStyle(theme.label)
        }
        // An LED shows only its name; its knee voltage is in its editor. One
        // with too much current gets a warning instead.
        if component.kind == .led {
            value = solution.ledOvercurrent[component.id] == nil
                ? Text("")
                : Text("⚠ For meget strøm").font(font.weight(.semibold)).foregroundStyle(SymbolRenderer.warningColor)
        }
        if component.start.y == component.end.y {
            context.draw(name, at: CGPoint(x: mid.x, y: mid.y - unit * 1.1), anchor: .bottom)
            context.draw(value, at: CGPoint(x: mid.x, y: mid.y + unit * 1.1), anchor: .top)
        } else {
            context.draw(name, at: CGPoint(x: mid.x + unit * 1.2, y: mid.y), anchor: .bottomLeading)
            context.draw(value, at: CGPoint(x: mid.x + unit * 1.2, y: mid.y), anchor: .topLeading)
        }
    }

    /// A power circle: a circle around the component with "P_R1 = value"
    /// beside it at the upper right. Absorbed power is positive, delivered
    /// power (e.g. from a source) negative.
    private func drawPowerCircle(around component: CircuitComponent, in context: GraphicsContext) {
        let a = screenPoint(component.start)
        let b = screenPoint(component.end)
        let center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        // Wide enough to hold the symbol with its name and value labels.
        let radius = a.distance(to: b) / 2 + unit * 0.6
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let color = editor.isSelected(.component(component.id)) ? theme.selection : theme.power
        context.fill(circle, with: .color(theme.power.opacity(0.06)))
        context.stroke(circle, with: .color(color), lineWidth: max(1, 1.5 * scale))

        let size = max(7, unit * 0.6)
        let font = Font.system(size: size, weight: .semibold)
        var text = subscriptedName(component.powerName, font: font, size: size, color: color)
        if let power = solution.powerValues[component.id] {
            text = Text("\(text)\(Text(" = " + SIValue.format(power, unit: "W")).font(font.italic()).foregroundStyle(theme.computed))")
        } else {
            text = Text("\(text)\(Text(" = " + SIValue.format(nil, unit: "W")).font(font).foregroundStyle(color))")
        }
        let corner = CGPoint(x: center.x + radius * 0.72, y: center.y - radius * 0.72)
        context.draw(text, at: CGPoint(x: corner.x + unit * 0.15, y: corner.y - unit * 0.15), anchor: .bottomLeading)
    }

    /// An equivalent resistance: a grey resistor with its name and value in
    /// the color of the resistors it combines.
    private func drawEquivalent(_ equivalent: EquivalentResistance, in context: GraphicsContext) {
        let a = screenPoint(equivalent.start)
        let b = screenPoint(equivalent.end)
        let isSelected = editor.isSelected(.equivalent(equivalent.id))
        SymbolRenderer.drawComponent(
            .resistor, from: a, to: b, unit: unit, color: isSelected ? theme.selection : theme.equivalentSymbol,
            lineWidth: max(1, 2 * scale), resistorStyle: resistorStyle, in: context
        )

        let color = theme.groupColor(equivalent.colorIndex)
        let size = max(7, unit * 0.6)
        let font = Font.system(size: size, weight: .semibold)
        let name = subscriptedName(equivalent.name, font: font, size: size, color: color)
        let valueText = studyMode ? SIValue.format(nil, unit: "Ω") : editor.equivalentResults[equivalent.id]?.formatted ?? SIValue.format(nil, unit: "Ω")
        let value = Text(valueText).font(font).foregroundStyle(color)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        if equivalent.start.y == equivalent.end.y {
            context.draw(name, at: CGPoint(x: mid.x, y: mid.y - unit * 1.1), anchor: .bottom)
            context.draw(value, at: CGPoint(x: mid.x, y: mid.y + unit * 1.1), anchor: .top)
        } else {
            context.draw(name, at: CGPoint(x: mid.x + unit * 1.2, y: mid.y), anchor: .bottomLeading)
            context.draw(value, at: CGPoint(x: mid.x + unit * 1.2, y: mid.y), anchor: .topLeading)
        }
    }

    /// A filled arrowhead on the wire with the current's name and value beside it.
    private func drawCurrentArrow(_ arrow: CurrentArrow, at point: CGPoint, direction: CGPoint, color: Color, in context: GraphicsContext) {
        SymbolRenderer.drawCurrentArrowhead(at: point, direction: direction, size: unit * 0.9, color: color, in: context)

        drawValueLabel(
            name: arrow.name, value: arrow.value, measured: solution.measurementText(arrow.id, mode: arrow.measure, unit: "A", at: frameTime),
            unit: "A", color: color, in: context
        ) { text in
            if abs(direction.x) > abs(direction.y) {
                context.draw(text, at: CGPoint(x: point.x, y: point.y - unit * 0.55), anchor: .bottom)
            } else {
                context.draw(text, at: CGPoint(x: point.x + unit * 0.55, y: point.y), anchor: .leading)
            }
        }
    }

    /// A logic gate, input or output, drawn by the shared `SymbolPainter`
    /// like on the web.
    private func drawGate(_ gate: LogicGate, color: SceneColor, value: Bool?, in context: GraphicsContext) {
        var painter = SymbolPainter(unit: unit)
        let scene = theme.scene
        painter.gate(gate, at: screenPoint(gate.position), color: color, lineWidth: max(1, 2 * scale), value: value, high: scene.logicHigh, textColor: scene.label)
        ScenePrimitiveRenderer.draw(painter.primitives, in: context)
    }

    private func drawGround(at position: GridPoint, rotation: Int, color: Color, in context: GraphicsContext) {
        let direction = Ground(position: position, rotation: rotation).direction
        SymbolRenderer.drawGround(
            at: screenPoint(position),
            direction: CGPoint(x: direction.x, y: direction.y),
            unit: unit,
            color: color,
            lineWidth: max(1, 2 * scale),
            in: context
        )
    }

    /// The sense markers of controlled sources: + and − points joined by a
    /// dashed line with a movable "Vs" label, and the Is point with an arrow.
    /// Excluded areas: what's inside is dimmed, with a dashed border and a
    /// note in the corner. The one being drawn is shown too.
    private func drawExcludedAreas(in context: GraphicsContext) {
        var rects = editor.circuit.excludedAreas.map { area in
            (rect: CGRect(p1: screenPoint(area.from), p2: screenPoint(area.to)), isSelected: editor.isSelected(.excludedArea(area.id)))
        }
        if let draft = exclusionDraft {
            rects.append((CGRect(p1: screenPoint(snap(draft.start)), p2: screenPoint(snap(draft.current))), false))
        }
        let font = Font.system(size: max(7, unit * 0.5), weight: .medium)
        for (rect, isSelected) in rects {
            let path = Path(roundedRect: rect, cornerRadius: 4)
            context.fill(path, with: .color(theme.sheet.opacity(0.55)))
            let color = isSelected ? theme.selection : theme.computed
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: isSelected ? 2 : 1.2, dash: [6, 4]))
            context.draw(
                Text("Udeladt af beregning").font(font).foregroundStyle(color),
                at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), anchor: .topLeading
            )
        }
    }

    /// Groups: a lightly tinted box with a thin border and the name in the
    /// top-left corner, drawn beneath the circuit.
    private func drawGroupAreas(in context: GraphicsContext) {
        let size = max(8, unit * 0.6)
        for group in editor.circuit.groupAreas {
            let color = Color(red: group.red, green: group.green, blue: group.blue)
            let isSelected = editor.isSelected(.groupArea(group.id))
            let rect = CGRect(p1: screenPoint(group.from), p2: screenPoint(group.to))
            let path = Path(roundedRect: rect, cornerRadius: 6)
            context.fill(path, with: .color(color.opacity(colorScheme == .dark ? 0.16 : 0.09)))
            context.stroke(path, with: .color(isSelected ? theme.selection : color.opacity(0.55)), lineWidth: isSelected ? 2 : 1)
            context.draw(
                Text(group.name).font(.system(size: size, weight: .semibold)).foregroundStyle(isSelected ? theme.selection : color),
                at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), anchor: .topLeading
            )
        }
    }

    /// The selected group's handle under a screen point, if any.
    private func groupHandle(at location: CGPoint) -> (UUID, GroupArea.Handle)? {
        guard case .groupArea(let id) = editor.selection, let group = editor.groupArea(id: id) else { return nil }
        let reach = max(9, unit * 0.45)
        let handle = GroupArea.Handle.all.min { a, b in
            handleScreenPoint(group, a).distance(to: location) < handleScreenPoint(group, b).distance(to: location)
        }
        guard let handle, handleScreenPoint(group, handle).distance(to: location) <= reach else { return nil }
        return (id, handle)
    }

    private func handleScreenPoint(_ group: GroupArea, _ handle: GroupArea.Handle) -> CGPoint {
        let p = group.position(of: handle)
        return CGPoint(x: p.x * unit + offset.width, y: p.y * unit + offset.height)
    }

    /// Dots in the corners and the middle of the sides of the selected group,
    /// for resizing it. Drawn on top of the circuit so they can be seen.
    private func drawGroupHandles(in context: GraphicsContext) {
        guard case .groupArea(let id) = editor.selection, let group = editor.groupArea(id: id) else { return }
        let radius = max(4, unit * 0.22)
        for handle in GroupArea.Handle.all {
            let p = handleScreenPoint(group, handle)
            let dot = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(theme.sheet))
            context.stroke(dot, with: .color(theme.selection), lineWidth: 1.5)
        }
    }

    /// A voltage drop: + and − markers with a dashed bracket through the
    /// label, like a voltage-controlled source's Vs, and "V_A = value".
    private func drawVoltageDrop(_ probe: Probe, in context: GraphicsContext) {
        guard let negative = probe.negative, let label = editor.voltageDropLabelPosition(of: probe) else { return }
        let a = screenPoint(probe.position)
        let b = screenPoint(negative)
        let labelPoint = CGPoint(x: label.x * unit + offset.width, y: label.y * unit + offset.height)
        drawMarkerPair(
            plus: a, minus: b, label: labelPoint,
            plusColor: editor.isSelected(.probe(probe.id)) ? theme.selection : theme.probe,
            minusColor: editor.isSelected(.probeMinus(probe.id)) ? theme.selection : theme.probe,
            lineColor: theme.probe, in: context
        )

        let isLabelSelected = editor.isSelected(.probeLabel(probe.id))
        let color = isLabelSelected ? theme.selection : theme.probe
        let size = max(7, unit * 0.6)
        let font = Font.system(size: size, weight: .semibold)
        var text = subscriptedName(probe.name, font: font, size: size, color: color)
        if let value = probe.value {
            let valueColor = isLabelSelected ? color : (editor.isInherited(probe.name) ? theme.inherited : color)
            text = Text("\(text)\(Text(" = " + SIValue.format(value, unit: "V")).font(font).foregroundStyle(valueColor))")
        } else if let measured = solution.measurementText(probe.id, mode: probe.measure, unit: "V", at: frameTime) {
            text = Text("\(text)\(Text(" = " + measured).font(font.italic()).foregroundStyle(theme.computed))")
        }
        context.draw(text, at: labelPoint, anchor: .center)
    }

    /// A mesh current: a curved arrow with its name in the middle.
    private func drawMeshMarker(at point: CGPoint, name: String, clockwise: Bool, color: Color, in context: GraphicsContext) {
        SymbolRenderer.drawMeshArrow(at: point, radius: unit * 1.1, clockwise: clockwise, color: color, lineWidth: max(1, 1.8 * scale), in: context)
        let size = max(8, unit * 0.7)
        context.draw(subscriptedName(name, font: .system(size: size, weight: .semibold), size: size, color: color), at: point, anchor: .center)
    }

    /// A name like V_{A} or R__eq with its subscript lowered and smaller.
    private func subscriptedName(_ name: String, font: Font, size: CGFloat, weight: Font.Weight = .semibold, color: Color) -> Text {
        guard let underscore = name.firstIndex(of: "_") else {
            return Text(name).font(font).foregroundStyle(color)
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
        let lowered = Text(sub).font(.system(size: size * 0.7, weight: weight)).baselineOffset(-size * 0.25).foregroundStyle(color)
        let after = Text(tail).font(font).foregroundStyle(color)
        return Text("\(Text(base).font(font).foregroundStyle(color))\(lowered)\(after)")
    }

    /// + and − markers with a dashed line from each to the label, like a
    /// bracket: vertical from the label when the markers are above each
    /// other, horizontal when they're side by side.
    private func drawMarkerPair(
        plus a: CGPoint, minus b: CGPoint, label labelPoint: CGPoint,
        plusColor: Color, minusColor: Color, lineColor: Color, in context: GraphicsContext
    ) {
        let radius = max(5, unit * 0.42)
        func circle(at p: CGPoint) -> Path {
            Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        }
        let gap = max(9, unit * 0.75)
        let markersStacked = abs(a.y - b.y) >= abs(a.x - b.x)
        var line = Path()
        for end in [a, b] {
            let corner = markersStacked ? CGPoint(x: labelPoint.x, y: end.y) : CGPoint(x: end.x, y: labelPoint.y)
            let points = trimmed([labelPoint, corner, end], start: gap, end: radius)
            guard let first = points.first else { continue }
            line.move(to: first)
            for point in points.dropFirst() { line.addLine(to: point) }
        }
        context.stroke(line, with: .color(lineColor.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        for (point, color, isPlus) in [(a, plusColor, true), (b, minusColor, false)] {
            context.fill(circle(at: point), with: .color(theme.sheet))
            context.stroke(circle(at: point), with: .color(color), lineWidth: 1.5)
            let size = radius * 0.5
            var sign = Path()
            sign.move(to: CGPoint(x: point.x - size, y: point.y))
            sign.addLine(to: CGPoint(x: point.x + size, y: point.y))
            if isPlus {
                sign.move(to: CGPoint(x: point.x, y: point.y - size))
                sign.addLine(to: CGPoint(x: point.x, y: point.y + size))
            }
            context.stroke(sign, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    private func drawSenseMarkers(in context: GraphicsContext) {
        let circuit = editor.circuit
        let size = max(7, unit * 0.6)
        func screen(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * unit + offset.width, y: p.y * unit + offset.height)
        }
        let radius = max(5, unit * 0.42)
        func circle(at p: CGPoint) -> Path {
            Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        }

        for component in circuit.components where component.kind.isVoltageControlled {
            guard let plus = circuit.sense(of: component.id, .plus),
                  let minus = circuit.sense(of: component.id, .minus) else { continue }
            let a = screen(plus.point)
            let b = screen(minus.point)
            // The dashed line runs from + through the "Vs" label to −, so it
            // follows the label, and stops short of it in a circle around it.
            let labelPoint = editor.senseLabelPosition(of: component).map(screen)
                ?? CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let gap = max(9, unit * 0.75)
            var line = Path()
            // Markers above each other: vertical from the label, then horizontal
            // into each marker, like a bracket beside what's measured. Markers
            // side by side: the other way round.
            let markersStacked = abs(a.y - b.y) >= abs(a.x - b.x)
            for end in [a, b] {
                // Leave out the part inside the gap and the part under the marker.
                let corner = markersStacked ? CGPoint(x: labelPoint.x, y: end.y) : CGPoint(x: end.x, y: labelPoint.y)
                let points = trimmed([labelPoint, corner, end], start: gap, end: radius)
                guard let first = points.first else { continue }
                line.move(to: first)
                for point in points.dropFirst() { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(theme.control.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))

            let labelColor = editor.isSelected(.senseLabel(component.id)) ? theme.selection : theme.control
            context.draw(
                subscriptedName(component.controlLabel, font: .system(size: size, weight: .semibold), size: size, color: labelColor),
                at: labelPoint, anchor: .center
            )

            for (marker, point) in [(plus, a), (minus, b)] {
                let color = editor.isSelected(.sense(marker.id)) ? theme.selection : theme.control
                context.fill(circle(at: point), with: .color(theme.sheet))
                context.stroke(circle(at: point), with: .color(color), lineWidth: 1.5)
                // "+" or "−" inside
                let size = radius * 0.5
                var sign = Path()
                sign.move(to: CGPoint(x: point.x - size, y: point.y))
                sign.addLine(to: CGPoint(x: point.x + size, y: point.y))
                if marker.kind == .plus {
                    sign.move(to: CGPoint(x: point.x, y: point.y - size))
                    sign.addLine(to: CGPoint(x: point.x, y: point.y + size))
                }
                context.stroke(sign, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }

        for component in circuit.components where component.kind.isCurrentControlled {
            guard let marker = circuit.sense(of: component.id, .current) else { continue }
            let point = screen(marker.point)
            let color = editor.isSelected(.sense(marker.id)) ? theme.selection : theme.control
            let arrow = circuit.currentArrow(for: marker)
            let placement = arrow.flatMap { circuit.placement(of: $0) }
            // Not on a wire yet: dashed outline and a horizontal arrow.
            context.fill(circle(at: point), with: .color(theme.sheet))
            context.stroke(
                circle(at: point), with: .color(color),
                style: StrokeStyle(lineWidth: 1.5, dash: placement == nil ? [3, 2] : [])
            )
            var direction = placement?.direction ?? CGPoint(x: marker.flipped ? -1 : 1, y: 0)
            let length = hypot(direction.x, direction.y)
            if length > 0 { direction = CGPoint(x: direction.x / length, y: direction.y / length) }
            SymbolRenderer.drawCurrentArrowhead(at: point, direction: direction, size: radius * 1.1, color: color, in: context)

            let isVertical = abs(direction.y) > abs(direction.x)
            let labelPoint = isVertical
                ? CGPoint(x: point.x + radius + 3, y: point.y)
                : CGPoint(x: point.x, y: point.y - radius - 2)
            context.draw(
                subscriptedName(component.controlLabel, font: .system(size: size, weight: .semibold), size: size, color: color),
                at: labelPoint, anchor: isVertical ? .leading : .bottom
            )
        }
    }

    /// A polyline shortened by `start` at its beginning and `end` at its end.
    /// Empty if nothing is left.
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

    /// A component value with its unit; gains as ratios: 2 V/V, 3 mA/V.
    private func gainOrValue(_ value: Double, of component: CircuitComponent) -> String {
        SIValue.format(value, unit: component.kind.displayUnit)
    }

    /// A "Name = value" label, or just the name while the value is unknown.
    /// A value the calculation filled in is shown in grey italics.
    private func drawValueLabel(
        name: String, value: Double?, measured: String?, unit valueUnit: String, color: Color,
        in context: GraphicsContext, place: (Text) -> Void
    ) {
        let size = max(7, unit * 0.6)
        let font = Font.system(size: size, weight: .medium)
        let nameText = subscriptedName(name, font: font, size: size, weight: .medium, color: color)
        if let value {
            // A value given by a "!name := …" line in a text box is shown in purple.
            let valueColor = editor.isInherited(name) ? theme.inherited : color
            let valueText = Text(" = " + SIValue.format(value, unit: valueUnit)).font(font).foregroundStyle(valueColor)
            place(Text("\(nameText)\(valueText)"))
        } else if let measured {
            // Computed, the way the voltage point or current picked (MeasureMode),
            // e.g. "2 V ∠ 30°  ~ 0,4 V ∠ −80°" or "7,07 V rms".
            let valueText = Text(" = " + measured).font(font.italic()).foregroundStyle(theme.computed)
            place(Text("\(nameText)\(valueText)"))
        } else {
            place(nameText)
        }
    }

    private func drawSelectionRect(in context: GraphicsContext) {
        guard case .selectingArea(let start, let current) = dragMode else { return }
        let rect = CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(start.x - current.x), height: abs(start.y - current.y)
        )
        context.fill(Path(rect), with: .color(theme.selection.opacity(0.1)))
        context.stroke(Path(rect), with: .color(theme.selection), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    private func drawPreview(in context: GraphicsContext) {
        var preview = context
        preview.opacity = 0.55
        let wireStyle = StrokeStyle(lineWidth: max(1, 2 * scale), lineCap: .round, lineJoin: .round)

        // The wire being routed: fixed segments solid, the next one faded.
        if editor.isRouting, let last = editor.routing.last {
            var fixed = Path()
            fixed.addLines(editor.routing.map(screenPoint))
            context.stroke(fixed, with: .color(theme.wire), style: wireStyle)
            for point in editor.routing {
                drawSupportPoint(point, in: context)
            }
            if let hoverPoint, hoverPoint != last {
                preview.stroke(lPath(from: last, to: hoverPoint), with: .color(theme.wire), style: wireStyle)
            }
            return
        }

        // A Req's first point, with a dashed line to where the second would go.
        if editor.tool == .equivalent, let start = editor.pendingEquivalentPoint {
            let a = screenPoint(start)
            if let hoverPoint, hoverPoint != start {
                var line = Path()
                line.move(to: a)
                line.addLine(to: screenPoint(hoverPoint))
                preview.stroke(line, with: .color(theme.equivalentSymbol), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            let radius = max(4, unit * 0.3)
            context.fill(
                Path(ellipseIn: CGRect(x: a.x - radius, y: a.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(theme.equivalentSymbol)
            )
            return
        }

        // The ground tool shows a ghost where it will be placed.
        if editor.tool == .ground, let point = hoverPoint {
            if case .cancelled = dragMode { return }
            drawGround(at: point, rotation: editor.placementRotation, color: theme.component, in: preview)
            return
        }

        // A component tool with a pointer shows a ghost of the tap placement.
        if case .component(let kind) = editor.tool, case .idle = dragMode, let hoverPoint {
            let (a, b) = editor.defaultTerminals(centeredAt: hoverPoint)
            SymbolRenderer.drawComponent(
                kind, from: screenPoint(a), to: screenPoint(b), unit: unit,
                color: theme.component, lineWidth: max(1, 2 * scale), resistorStyle: resistorStyle, in: preview
            )
            return
        }
        if editor.tool == .mesh, case .idle = dragMode, let hoverPoint {
            drawMeshMarker(at: screenPoint(hoverPoint), name: editor.circuit.nextMeshName(), clockwise: editor.meshPlacementClockwise, color: theme.current, in: preview)
            return
        }
        // The inverter tool rings the terminal a click would invert.
        if editor.tool == .invert, let hoverLocation,
           let hit = editor.invertiblePin(near: worldPoint(hoverLocation), tolerance: 12 / scale) {
            let center = CGPoint(x: hit.center.x * unit + offset.width, y: hit.center.y * unit + offset.height)
            let radius = max(6, unit * 0.45)
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(theme.selection), lineWidth: 1.5
            )
            return
        }
        // A gate tool shows a ghost of the gate where it will be placed.
        if case .gate(let kind) = editor.tool, let hoverPoint {
            if case .cancelled = dragMode { return }
            let ghost = editor.newGate(kind, at: hoverPoint)
            drawGate(ghost, color: theme.scene.component, value: nil, in: preview)
            return
        }

        guard case .drawing(let start, let current) = dragMode else { return }
        switch editor.tool {
        case .wire where drawingRectangle:
            guard start.x != current.x, start.y != current.y else { return }
            preview.stroke(Path(CGRect(p1: screenPoint(start), p2: screenPoint(current))), with: .color(theme.wire), style: wireStyle)
        case .wire:
            guard start != current else { return }
            preview.stroke(lPath(from: start, to: current), with: .color(theme.wire), style: wireStyle)
        case .component(let kind):
            let (a, b) = componentTerminals(start: start, current: current)
            SymbolRenderer.drawComponent(
                kind, from: screenPoint(a), to: screenPoint(b), unit: unit,
                color: theme.component, lineWidth: max(1, 2 * scale), resistorStyle: resistorStyle, in: preview
            )
        case .probe:
            if placingVoltageDrop, start != current {
                let a = screenPoint(start), b = screenPoint(current)
                let stacked = abs(a.y - b.y) >= abs(a.x - b.x)
                let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let label = stacked ? CGPoint(x: middle.x - 1.5 * unit, y: middle.y) : CGPoint(x: middle.x, y: middle.y - 1.5 * unit)
                drawMarkerPair(plus: a, minus: b, label: label, plusColor: theme.probe, minusColor: theme.probe, lineColor: theme.probe, in: preview)
            } else {
                SymbolRenderer.drawProbe(at: screenPoint(current), unit: unit, color: theme.probe, in: preview)
            }
        case .mesh:
            drawMeshMarker(at: screenPoint(current), name: editor.circuit.nextMeshName(), clockwise: editor.meshPlacementClockwise, color: theme.current.opacity(0.5), in: preview)
        case .groupArea:
            guard start.x != current.x, start.y != current.y else { return }
            let (red, green, blue) = GroupArea.palette[editor.circuit.groupAreas.count % GroupArea.palette.count]
            let color = Color(red: red, green: green, blue: blue)
            let rect = Path(roundedRect: CGRect(p1: screenPoint(start), p2: screenPoint(current)), cornerRadius: 6)
            preview.fill(rect, with: .color(color.opacity(0.1)))
            preview.stroke(rect, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        case .power:
            // The circle follows the pointer rather than the grid.
            guard let draft = powerDraft else { return }
            let circle = Path(ellipseIn: CGRect(p1: draft.start, p2: draft.current))
            preview.fill(circle, with: .color(theme.power.opacity(0.08)))
            preview.stroke(circle, with: .color(theme.power), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        case .select, .current, .ground, .equivalent, .text, .gate, .invert:
            break
        }
    }

    /// An L-shaped path, horizontal first, matching how wires are created.
    private func lPath(from start: GridPoint, to end: GridPoint) -> Path {
        var path = Path()
        path.move(to: screenPoint(start))
        path.addLine(to: screenPoint(GridPoint(x: end.x, y: start.y)))
        path.addLine(to: screenPoint(end))
        return path
    }

    private func drawSupportPoint(_ point: GridPoint, in context: GraphicsContext) {
        let p = screenPoint(point)
        let size = max(4, unit * 0.25)
        context.stroke(
            Path(CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)),
            with: .color(theme.wire),
            lineWidth: 1
        )
    }

    /// A KiCad-style crosshair marking the grid point the pen will snap to.
    /// The freehand lines drawn with the pencil, and the one being drawn.
    private func drawStrokes(in context: GraphicsContext) {
        let pending = Stroke(points: currentStroke, color: editor.penColor, size: editor.penSize)
        for stroke in editor.circuit.strokes + [pending] where !stroke.xs.isEmpty {
            var path = Path()
            path.addLines(stroke.points.map { CGPoint(x: $0.x * unit + offset.width, y: $0.y * unit + offset.height) })
            let style = StrokeStyle(lineWidth: max(0.5, stroke.width * scale), lineCap: .round, lineJoin: .round)
            context.stroke(path, with: .color(theme.penColor(stroke.color)), style: style)
        }
    }

    /// The eraser's outline under the pointer.
    private func drawEraser(in context: GraphicsContext) {
        guard editor.isDrawing, editor.isErasing, let eraserLocation else { return }
        let r = Self.eraserRadius
        let circle = Path(ellipseIn: CGRect(x: eraserLocation.x - r, y: eraserLocation.y - r, width: 2 * r, height: 2 * r))
        context.fill(circle, with: .color(theme.sheet.opacity(0.5)))
        context.stroke(circle, with: .color(theme.gridMajor), lineWidth: 1)
    }

    private func drawCrosshair(in context: GraphicsContext, size: CGSize) {
        guard editor.tool != .select, !editor.isDrawing, let hoverPoint else { return }
        let p = screenPoint(hoverPoint)
        let arm = max(unit * 4, 40)
        var path = Path()
        path.move(to: CGPoint(x: p.x - arm, y: p.y))
        path.addLine(to: CGPoint(x: p.x + arm, y: p.y))
        path.move(to: CGPoint(x: p.x, y: p.y - arm))
        path.addLine(to: CGPoint(x: p.x, y: p.y + arm))
        context.stroke(path, with: .color(theme.crosshair), lineWidth: 0.75)

        // A ring shows that a click here will connect and finish the wire,
        // or pick a point for a Req.
        if (editor.tool == .wire && editor.circuit.isConnectionPoint(hoverPoint))
            || (editor.tool == .equivalent && editor.isEquivalentPoint(hoverPoint)) {
            let radius = max(6, unit * 0.45)
            context.stroke(
                Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(theme.wire),
                lineWidth: 1.5
            )
        }
    }

}

/// Colors for the schematic, adapting to light and dark appearance.
struct SchematicTheme {
    let background: CanvasBackground
    let customColor: Color.Resolved
    let colorScheme: ColorScheme

    /// Whether the sheet is dark, so lines and text need light colors.
    var isDark: Bool {
        switch background {
        case .system: colorScheme == .dark
        case .paper, .white, .gray: false
        case .dark, .blueprint: true
        case .custom: customColor.isDark
        }
    }

    var sheet: Color {
        switch background {
        case .system: colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.957, green: 0.953, blue: 0.937)
        case .paper: Color(red: 0.957, green: 0.953, blue: 0.937)
        case .white: .white
        case .gray: Color(white: 0.86)
        case .dark: Color(red: 0.11, green: 0.11, blue: 0.12)
        case .blueprint: Color(red: 0.07, green: 0.2, blue: 0.4)
        case .custom: Color(customColor)
        }
    }

    /// A shade laid over the sheet color outside the page.
    var outsidePage: Color { isDark ? Color.black.opacity(0.35) : Color.black.opacity(0.12) }
    var gridMinor: Color { isDark ? Color.white.opacity(0.25) : Color.black.opacity(0.24) }
    var gridMajor: Color { isDark ? Color.white.opacity(0.42) : Color.black.opacity(0.38) }
    var wire: Color { isDark ? Color(red: 0.35, green: 0.85, blue: 0.5) : Color(red: 0.0, green: 0.48, blue: 0.24) }
    var component: Color { isDark ? Color(red: 1.0, green: 0.47, blue: 0.45) : Color(red: 0.62, green: 0.1, blue: 0.12) }
    var label: Color { isDark ? Color(red: 0.6, green: 0.82, blue: 1.0) : Color(red: 0.08, green: 0.33, blue: 0.55) }
    var probe: Color { Color(red: 0.9, green: 0.45, blue: 0.05) }
    var current: Color { isDark ? Color(red: 0.8, green: 0.6, blue: 1.0) : Color(red: 0.45, green: 0.15, blue: 0.7) }
    /// Power circles around components.
    var power: Color { isDark ? Color(red: 1.0, green: 0.78, blue: 0.2) : Color(red: 0.78, green: 0.45, blue: 0.0) }
    var selection: Color { .accentColor }
    /// Sense markers (Vs, Is) of controlled sources.
    var control: Color { isDark ? Color(red: 0.35, green: 0.85, blue: 0.9) : Color(red: 0.0, green: 0.45, blue: 0.55) }
    /// The pen colors for freehand drawing: ink, red, green, orange and purple.
    func penColor(_ index: Int) -> Color {
        switch index {
        case 1: isDark ? Color(red: 1.0, green: 0.42, blue: 0.4) : Color(red: 0.82, green: 0.12, blue: 0.12)
        case 2: isDark ? Color(red: 0.4, green: 0.85, blue: 0.45) : Color(red: 0.1, green: 0.55, blue: 0.2)
        case 3: isDark ? Color(red: 1.0, green: 0.7, blue: 0.25) : Color(red: 0.9, green: 0.5, blue: 0.0)
        case 4: isDark ? Color(red: 0.8, green: 0.55, blue: 1.0) : Color(red: 0.5, green: 0.2, blue: 0.8)
        default: isDark ? Color(white: 0.92) : Color(white: 0.1)
        }
    }

    /// Values given by a "!name := …" line in a text box.
    var inherited: Color { isDark ? Color(red: 0.8, green: 0.55, blue: 1.0) : Color(red: 0.55, green: 0.2, blue: 0.85) }
    /// Values filled in by the automatic calculation.
    var computed: Color { isDark ? Color(white: 0.62) : Color(white: 0.47) }
    /// The symbol of an equivalent resistance (Req).
    var equivalentSymbol: Color { isDark ? Color(white: 0.58) : Color(white: 0.55) }

    /// Colors marking which resistors make up each Req, repeating after six.
    func groupColor(_ index: Int) -> Color {
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
        return Color(red: red, green: green, blue: blue)
    }

    var crosshair: Color { isDark ? Color(white: 0.7) : Color(white: 0.35) }
    /// Wires carrying a 1 on a digital sheet.
    var logicHigh: Color { Color(scene.logicHigh) }
    /// The same colors for the shared drawing code (logic symbols).
    var scene: SheetTheme { SheetTheme(isDark: isDark) }
}

private extension CGRect {
    /// The rectangle with two opposite corners at `p1` and `p2`.
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }
}
