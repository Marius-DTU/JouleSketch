#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import JavaScriptKit

/// The bridge between the web page and the shared Swift code. Everything the
/// page does goes through here: pointer and key events go to
/// `SheetInteraction` and `CircuitEditor`, and the page draws the primitives
/// from `SchematicScene`. Results are passed as JSON strings.
@JS final class JouleApp {
    private let editor = CircuitEditor()
    private let interaction: SheetInteraction
    private let undo = UndoManager()
    private var viewSize = CGSize(width: 800, height: 600)
    private var keyBindings = KeyBindings()
    private var resistorStyle = SceneResistorStyle.iec
    private var showGrid = true
    private var studyMode = false
    /// Where the primary button went down, while it's held.
    private var pressLocation: CGPoint?
    private var rightLocation: CGPoint?

    @JS init() {
        interaction = SheetInteraction(editor: editor)
        editor.undoManager = undo
    }

    // MARK: Files

    /// Opens a .joulesketch file. Returns an error message, or "" on success.
    @JS func open(_ json: String) -> String {
        do {
            let file = try JSONDecoder().decode(CircuitFile.self, from: Data(json.utf8))
            editor.load(file.circuit)
            undo.removeAllActions()
            editor.resetView()
            return ""
        } catch {
            return "Filen kunne ikke åbnes: \(error)"
        }
    }

    /// The document as a .joulesketch file.
    @JS func save() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(CircuitFile(circuit: editor.circuit)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @JS func newDocument() {
        editor.load(Circuit())
        undo.removeAllActions()
        editor.resetView()
    }

    // MARK: Settings

    @JS func setSettings(_ json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        if let value = object["resistorStyle"] as? String, let style = SceneResistorStyle(rawValue: value) { resistorStyle = style }
        if let value = object["showGrid"] as? Bool { showGrid = value }
        if let value = object["studyMode"] as? Bool { studyMode = value }
        if let value = object["keyBindings"] as? String { keyBindings = KeyBindings(storageString: value) }
        if let width = object["pageWidth"] as? Int, let height = object["pageHeight"] as? Int {
            editor.pageSize = GridPoint(
                x: min(PageSize.range.upperBound, max(PageSize.range.lowerBound, width)),
                y: min(PageSize.range.upperBound, max(PageSize.range.lowerBound, height))
            )
        }
    }

    // MARK: View

    @JS func setViewSize(_ width: Double, _ height: Double) {
        viewSize = CGSize(width: width, height: height)
        editor.viewSize = viewSize
    }

    @JS func zoom(_ factor: Double, _ x: Double, _ y: Double) {
        editor.zoom(by: factor, around: CGPoint(x: x, y: y))
    }

    @JS func zoomAroundCenter(_ factor: Double) {
        editor.zoom(by: factor, around: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    @JS func resetView() {
        editor.resetView()
    }

    @JS func pan(_ dx: Double, _ dy: Double) {
        interaction.pan(by: CGSize(width: dx, height: dy))
    }

    @JS func zoomPercent() -> Int {
        Int((editor.scale * 100).rounded())
    }

    // MARK: Pointer

    @JS func pointerDown(_ x: Double, _ y: Double, _ command: Bool, _ shift: Bool) {
        let point = CGPoint(x: x, y: y)
        interaction.isCommandDown = command
        pressLocation = point
        interaction.drag(from: point, to: point, shift: shift)
    }

    @JS func pointerMove(_ x: Double, _ y: Double, _ command: Bool, _ shift: Bool) {
        let point = CGPoint(x: x, y: y)
        interaction.isCommandDown = command
        if let start = pressLocation {
            interaction.drag(from: start, to: point, shift: shift)
        } else {
            interaction.hover(at: point)
        }
    }

    @JS func pointerUp(_ x: Double, _ y: Double, _ command: Bool, _ shift: Bool) {
        let point = CGPoint(x: x, y: y)
        interaction.isCommandDown = command
        guard let start = pressLocation else { return }
        pressLocation = nil
        interaction.endDrag(from: start, to: point, shift: shift)
        interaction.hover(at: point)
    }

    @JS func pointerLeave() {
        if pressLocation == nil { interaction.hover(at: nil) }
    }

    /// The right button: pans, or with Ctrl draws an excluded area.
    @JS func rightDown(_ x: Double, _ y: Double, _ command: Bool) {
        interaction.isCommandDown = command
        rightLocation = CGPoint(x: x, y: y)
        interaction.beginRightDrag(at: CGPoint(x: x, y: y))
    }

    @JS func rightMove(_ x: Double, _ y: Double) {
        guard let last = rightLocation else { return }
        rightLocation = CGPoint(x: x, y: y)
        interaction.rightDrag(by: CGSize(width: x - last.x, height: y - last.y))
    }

    @JS func rightUp() {
        rightLocation = nil
        interaction.endRightDrag()
    }

    @JS func cancelDrag() {
        pressLocation = nil
        interaction.cancelDrag()
    }

    // MARK: Keys and commands

    /// A key pressed on the sheet without Ctrl or Alt. Returns whether it was used.
    @JS func key(_ characters: String) -> Bool {
        guard let action = keyBindings.action(for: characters) else { return false }
        switch action {
        case .rotate: editor.rotate()
        case .selectWholeWire: editor.selectWholeWires()
        default:
            guard let tool = action.tool else { return false }
            setTool(tool)
        }
        return true
    }

    @JS func setToolID(_ id: String) {
        if id == "pen" {
            editor.isDrawing = true
            editor.isErasing = false
        } else if id == "eraser" {
            editor.isDrawing = true
            editor.isErasing = true
        } else if let tool = Tool.allCases.first(where: { $0.id == id }) {
            setTool(tool)
        }
    }

    /// The palette's buttons in order, as JSON `[{id, title, shown, tools: [id]}]`,
    /// where `shown` is the tool the button shows and picks.
    @JS func toolGroups() -> String {
        let json = JSONWriter()
        json.array(ToolGroup.allCases) { group in
            json.object {
                json.field("id", group.id)
                json.field("title", group.title)
                json.field("shown", editor.shownTool(in: group).id)
                json.key("tools")
                json.array(group.tools) { json.value($0.id) }
            }
        }
        return json.text
    }

    private func setTool(_ tool: Tool) {
        editor.isDrawing = false
        editor.tool = tool
        interaction.resetDrag()
    }

    @JS func command(_ name: String) {
        switch name {
        case "undo": editor.undo()
        case "redo": editor.redo()
        case "delete": editor.deleteSelection()
        case "escape": editor.escape()
        case "rotate": editor.rotate()
        case "selectAll": editor.selectAll()
        case "selectWholeWire": editor.selectWholeWires()
        case "copy": editor.copySelection()
        case "paste": editor.paste(at: interaction.hoverPoint)
        case "clearAll": editor.clearAll()
        case "toggleVoltageDrops": editor.placesVoltageDrops.toggle()
        case "toggleMeshDirection": editor.meshPlacementClockwise.toggle()
        default: break
        }
    }

    // MARK: Key bindings

    /// Every rebindable action with its key, as JSON
    /// `[{action, name, key, command, shift, conflict}]`.
    @JS func keyBindingList() -> String {
        let conflicts = keyBindings.conflicts
        let json = JSONWriter()
        json.array(KeyAction.allCases) { action in
            json.object {
                json.field("action", action.rawValue)
                json.field("name", action.displayName)
                json.field("key", keyBindings[action])
                json.field("command", action.usesCommand)
                json.field("shift", action.usesShift)
                json.field("conflict", conflicts.contains(action))
            }
        }
        return json.text
    }

    /// Binds a key to an action ("" for none) and returns the bindings to store.
    @JS func setKeyBinding(_ action: String, _ key: String) -> String {
        if let action = KeyAction(rawValue: action) {
            keyBindings[action] = String(key.prefix(1))
        }
        return keyBindings.storageString
    }

    /// Puts every key back to its default and returns the bindings to store.
    @JS func resetKeyBindings() -> String {
        keyBindings = KeyBindings()
        return keyBindings.storageString
    }

    @JS func setPen(_ color: Int, _ size: Int) {
        editor.penColor = color
        editor.penSize = size
    }

    // MARK: Drawing

    /// Everything to draw on the sheet, as JSON (see `SceneJSON`).
    @JS func scene() -> String {
        var scene = SchematicScene(editor: editor, interaction: interaction, size: viewSize)
        scene.resistorStyle = resistorStyle
        scene.showGrid = showGrid
        scene.studyMode = studyMode
        return SceneJSON.encode(scene.build())
    }

    /// A palette icon (30 × 24 points) for a tool id, "pen" or "eraser", as
    /// scene JSON. White for the picked tool, like the Mac palette.
    @JS func toolIcon(_ id: String, _ active: Bool) -> String {
        let icon: ToolIconScene.Icon
        if id == "pen" {
            icon = .pen
        } else if id == "eraser" {
            icon = .eraser
        } else if let tool = Tool.allCases.first(where: { $0.id == id }) {
            icon = .tool(tool)
        } else {
            return "[]"
        }
        let color = active ? SceneColor(white: 1) : SceneColor(0.114, 0.114, 0.122)
        return SceneJSON.encode(ToolIconScene.primitives(for: icon, color: color, resistorStyle: resistorStyle))
    }

    /// The state the page shows around the sheet, as JSON.
    @JS func state() -> String {
        let json = JSONWriter()
        json.object {
            json.field("tool", editor.isDrawing ? (editor.isErasing ? "eraser" : "pen") : editor.tool.id)
            json.field("canUndo", undo.canUndo)
            json.field("canRedo", undo.canRedo)
            json.field("hasSelection", editor.selection != nil)
            json.field("selection", editor.selection.map(SelectionKey.encode))
            json.field("isRouting", editor.isRouting)
            json.field("placesVoltageDrops", editor.placesVoltageDrops)
            json.field("meshClockwise", editor.meshPlacementClockwise)
            json.field("zoom", zoomPercent())
            json.field("editing", editor.editingTextBox?.uuidString)
            json.field("isComplete", editor.solution.isComplete)
            json.field("issueCount", editor.solution.issues.filter { $0.kind != .notice }.count)
            json.key("textBoxes")
            json.array(editor.circuit.textBoxes) { box in
                let origin = interaction.screenPoint(box.position)
                json.object {
                    json.field("id", box.id.uuidString)
                    json.field("x", origin.x)
                    json.field("y", origin.y)
                    json.field("scale", editor.scale)
                    json.field("selected", editor.isSelected(.textBox(box.id)))
                    json.key("lines")
                    json.array(box.lines) { line in
                        json.object {
                            json.field("id", line.id.uuidString)
                            json.field("text", line.text)
                            json.field("isMath", line.isMath)
                        }
                    }
                }
            }
        }
        return json.text
    }

    /// The symbol whose editor a double-click asked for, as JSON with the
    /// item and its place on screen, or "" if none. Asking clears it.
    @JS func takeEditRequest() -> String {
        guard let request = interaction.editRequest else { return "" }
        interaction.editRequest = nil
        editor.beginEdit()
        let json = JSONWriter()
        json.object {
            json.field("item", SelectionKey.encode(request.item))
            json.field("x", request.anchor.minX)
            json.field("y", request.anchor.minY)
            json.field("width", request.anchor.width)
            json.field("height", request.anchor.height)
        }
        return json.text
    }

    /// Ends an editor opened with `takeEditRequest`, making its changes one undo step.
    @JS func endEdit() {
        editor.endEdit()
    }

    // MARK: Symbol editor

    /// The fields of an item's editor, as JSON, or "" if it has none.
    @JS func inspect(_ key: String) -> String {
        guard let item = SelectionKey.decode(key) else { return "" }
        let solution = studyMode ? editor.solution.withoutValues : editor.solution
        let json = JSONWriter()
        switch item {
        case .component(let id), .senseLabel(let id):
            guard let component = editor.component(id: id) else { return "" }
            json.object {
                json.field("type", "component")
                json.field("item", SelectionKey.encode(.component(id)))
                json.field("title", component.kind.displayName)
                json.field("name", component.name)
                if component.kind.isSwitch {
                    // Switches have no value; a switch has its position.
                    if component.kind == .toggleSwitch { json.field("closed", component.isClosed == true) }
                    if component.kind == .pushButton { json.field("normallyClosed", component.isNormallyClosed) }
                } else {
                    json.field("value", component.value.map { SIValue.format($0, unit: component.kind.displayUnit) } ?? "")
                    json.field("valueTitle", component.valueTitle ?? "Værdi (\(component.kind.displayUnit))")
                }
                json.field("computed", solution.componentValues[id].map { SIValue.format($0, unit: component.kind.displayUnit) })
                json.field("note", component.note)
                json.field("isDependent", component.kind.isDependent)
                json.field("controlName", component.controlName ?? "")
                json.field("controlPlaceholder", component.kind.isVoltageControlled ? "Vs" : "Is")
                json.field("showsPower", component.isPowerShown)
                json.field("power", solution.powerValues[id].map { SIValue.format($0, unit: "W") })
                if component.kind == .signalGenerator {
                    json.field("frequency", component.frequency.map { SIValue.format($0, unit: "Hz") } ?? "")
                    json.field("phase", SIValue.format(component.phase ?? 0, unit: "°"))
                    json.field("waveform", component.signalWaveform.rawValue)
                    json.field("hasDutyCycle", component.signalWaveform.hasDutyCycle)
                    json.field("isLowSideOutput", component.isLowSideOutput)
                    json.key("waveforms")
                    json.array(SignalWaveform.allCases) { waveform in
                        json.object {
                            json.field("id", waveform.rawValue)
                            json.field("name", waveform.displayName)
                        }
                    }
                    json.field("dutyCycle", SIValue.format(component.dutyCycle ?? 50, unit: "%"))
                }
            }
        case .sense(let id):
            guard let marker = editor.circuit.senses.first(where: { $0.id == id }) else { return "" }
            return inspect(SelectionKey.encode(.component(marker.ownerID)))
        case .probe(let id), .probeMinus(let id), .probeLabel(let id):
            guard let probe = editor.probe(id: id) else { return "" }
            json.object {
                json.field("type", "probe")
                json.field("item", SelectionKey.encode(.probe(id)))
                json.field("title", probe.isVoltageDrop ? "Spændingsfald" : "Spændingspunkt")
                json.field("name", probe.name)
                json.field("value", probe.value.map { SIValue.format($0, unit: "V") } ?? "")
                json.field("valueTitle", "Spænding (V)")
                json.field("computed", solution.probeValues[id].map {
                    [SIValue.format($0, unit: "V", phase: solution.phases[id]), solution.fundamentalText(id, unit: "V")].compactMap { $0 }.joined(separator: " ")
                })
                json.field("note", probe.note)
            }
        case .currentArrow(let id):
            guard let arrow = editor.currentArrow(id: id) else { return "" }
            json.object {
                json.field("type", "current")
                json.field("item", SelectionKey.encode(item))
                json.field("title", "Strøm i ledning")
                json.field("name", arrow.name)
                json.field("value", arrow.value.map { SIValue.format($0, unit: "A") } ?? "")
                json.field("valueTitle", "Strøm (A)")
                json.field("computed", solution.currentValues[id].map {
                    [SIValue.format($0, unit: "A", phase: solution.phases[id]), solution.fundamentalText(id, unit: "A")].compactMap { $0 }.joined(separator: " ")
                })
                json.field("note", arrow.note)
            }
        case .meshMarker(let id):
            guard let marker = editor.meshMarker(id: id) else { return "" }
            json.object {
                json.field("type", "mesh")
                json.field("item", SelectionKey.encode(item))
                json.field("title", "Maskestrøm")
                json.field("name", marker.name)
                json.field("clockwise", marker.clockwise)
            }
        case .groupArea(let id):
            guard let group = editor.groupArea(id: id) else { return "" }
            json.object {
                json.field("type", "group")
                json.field("item", SelectionKey.encode(item))
                json.field("title", "Gruppe")
                json.field("name", group.name)
            }
        default:
            return ""
        }
        return json.text
    }

    /// Changes one field of an item's editor. Values are parsed like the Mac
    /// app's value fields ("4,7k", "10 mA"). Returns an error message or "".
    @JS func setField(_ key: String, _ field: String, _ text: String) -> String {
        guard let item = SelectionKey.decode(key) else { return "" }
        // An empty value field means unknown.
        var value: Double?
        if ["value", "frequency", "phase", "dutyCycle"].contains(field), !text.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let number = SIValue.parse(text) else { return "Ugyldig værdi" }
            value = number
        }
        switch item {
        case .component(let id):
            switch field {
            case "name": editor.updateComponent(id: id) { $0.name = text }
            case "value":
                if let kind = editor.component(id: id)?.kind, let value, value < 0, !kind.allowsNegativeValue {
                    return "Værdien kan ikke være negativ"
                }
                editor.updateComponent(id: id) { $0.value = value }
            case "frequency":
                if let value, value <= 0 { return "Frekvensen skal være positiv" }
                editor.updateComponent(id: id) { $0.frequency = value }
            case "phase": editor.updateComponent(id: id) { $0.phase = value }
            case "waveform":
                let waveform = SignalWaveform(rawValue: text) ?? .sine
                editor.updateComponent(id: id) { $0.waveform = waveform == .sine ? nil : waveform }
            case "dutyCycle":
                if let value, value < 0 || value > 100 { return "Duty cycle skal være mellem 0 og 100 %" }
                editor.updateComponent(id: id) { $0.dutyCycle = value }
            case "note": editor.updateComponent(id: id) { $0.note = text }
            case "controlName": editor.updateComponent(id: id) { $0.controlName = text.isEmpty ? nil : text }
            case "showsPower": editor.setPowerShown(text == "true", id: id)
            case "closed": editor.updateComponent(id: id) { $0.isClosed = text == "true" ? true : nil }
            case "normallyClosed": editor.updateComponent(id: id) { $0.normallyClosed = text == "true" ? true : nil }
            case "flip": editor.flipComponent(id: id)
            default: break
            }
        case .probe(let id):
            switch field {
            case "name": editor.updateProbe(id: id) { $0.name = text }
            case "value": editor.updateProbe(id: id) { $0.value = value }
            case "note": editor.updateProbe(id: id) { $0.note = text }
            default: break
            }
        case .currentArrow(let id):
            switch field {
            case "name": editor.updateCurrentArrow(id: id) { $0.name = text }
            case "value": editor.updateCurrentArrow(id: id) { $0.value = value }
            case "note": editor.updateCurrentArrow(id: id) { $0.note = text }
            case "flip": editor.flipCurrentArrow(id: id)
            default: break
            }
        case .meshMarker(let id):
            switch field {
            case "name": editor.updateMeshMarker(id: id) { $0.name = text }
            case "flip": editor.flipMeshMarker(id: id)
            default: break
            }
        case .groupArea(let id):
            if field == "name" { editor.updateGroupArea(id: id) { $0.name = text } }
        default:
            break
        }
        return ""
    }

    // MARK: Text boxes

    @JS func setTextBoxSize(_ id: String, _ width: Double, _ height: Double) {
        guard let uuid = UUID(uuidString: id) else { return }
        // Measured on screen; the editor keeps world points.
        editor.textBoxSizes[uuid] = CGSize(width: width / editor.scale, height: height / editor.scale)
    }

    @JS func beginEditingTextBox(_ id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        editor.beginEditingTextBox(id: uuid)
    }

    @JS func endTextEditing() {
        editor.endTextEditing()
    }

    /// Replaces the lines of a text box while typing: JSON `[{id, text, isMath}]`.
    @JS func setTextBoxLines(_ id: String, _ json: String) {
        guard let uuid = UUID(uuidString: id),
              let lines = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return }
        editor.updateTextBox(id: uuid) { box in
            box.lines = lines.map { line in
                var textLine = TextLine()
                if let id = (line["id"] as? String).flatMap(UUID.init(uuidString:)) { textLine.id = id }
                textLine.text = line["text"] as? String ?? ""
                textLine.isMath = line["isMath"] as? Bool ?? false
                return textLine
            }
        }
    }

    // MARK: Calculation

    /// The "Beregning" report: what was computed, and what's missing or contradicts.
    @JS func report() -> String {
        let solution = editor.solution
        let json = JSONWriter()
        json.object {
            json.field("isConsistent", solution.isConsistent)
            json.field("isComplete", solution.isComplete)
            json.field("unknownCount", solution.unknownCount)
            json.field("solvedCount", solution.solvedCount)
            json.key("issues")
            json.array(solution.issues) { issue in
                json.object {
                    let kind = switch issue.kind {
                    case .conflict: "conflict"
                    case .missing: "missing"
                    case .notice: "notice"
                    }
                    json.field("kind", kind)
                    json.field("title", issue.title)
                    json.field("detail", issue.detail)
                }
            }
        }
        return json.text
    }

    /// The groups the Maple window can work with: JSON `[{id, name}]`.
    /// The guide behind the "i" button, with the current key bindings, as JSON.
    @JS func guide() -> String {
        let json = JSONWriter()
        json.array(UserGuide.sections(for: .web, keys: keyBindings)) { section in
            json.object {
                json.field("id", section.id)
                json.field("title", section.title)
                json.key("blocks")
                json.array(section.blocks) { block in
                    json.object {
                        switch block {
                        case .text(let text):
                            json.field("kind", "text")
                            json.field("text", text)
                        case .tip(let text):
                            json.field("kind", "tip")
                            json.field("text", text)
                        case .bullets(let items):
                            json.field("kind", "bullets")
                            json.key("items")
                            json.array(items) { json.value($0) }
                        case .keys(let rows):
                            json.field("kind", "keys")
                            json.key("rows")
                            json.array(rows) { row in
                                json.object {
                                    json.field("key", row.key)
                                    json.field("action", row.action)
                                }
                            }
                        }
                    }
                }
            }
        }
        return json.text
    }

    @JS func groups() -> String {
        let json = JSONWriter()
        json.array(editor.circuit.groupAreas) { group in
            json.object {
                json.field("id", group.id.uuidString)
                json.field("name", group.name)
            }
        }
        return json.text
    }

    /// A walkthrough by `method` ("nodal", "mesh" or "superposition") of the
    /// whole document or one group, with its Maple code, as JSON.
    @JS func walkthrough(_ method: String, _ groupID: String) -> String {
        var circuit = editor.calculationCircuit
        if let group = circuit.groupAreas.first(where: { $0.id.uuidString == groupID }) {
            circuit = circuit.inside(group)
        }
        let walkMethod = WalkMethod(rawValue: method) ?? .nodal
        let result = Walkthrough.make(walkMethod, for: circuit)
        let json = JSONWriter()
        json.object {
            switch result {
            case .unavailable(let reason):
                json.field("unavailable", reason)
                json.field("maple", walkMethod == .nodal ? MapleExporter.export(circuit) : nil)
            case .steps(let sections, let maple):
                json.field("maple", walkMethod == .nodal ? MapleExporter.export(circuit) : maple)
                json.key("sections")
                json.array(sections) { section in
                    json.object {
                        json.field("title", section.title)
                        json.key("lines")
                        json.array(section.lines) { line in
                            json.object {
                                switch line {
                                case .text(let text):
                                    json.field("math", false)
                                    json.field("text", text)
                                case .math(let text):
                                    json.field("math", true)
                                    json.field("text", text)
                                }
                            }
                        }
                    }
                }
            }
        }
        return json.text
    }

    /// Maple code as MathML, which Maple pastes as 2-D Math.
    @JS func mapleMathML(_ code: String) -> String {
        MapleMathML.convert(code)
    }
}

// MARK: - Selections as strings

/// Selections as text for the page: "component:ID", "wireSegment:ID:2",
/// and groups as their items joined by "|".
enum SelectionKey {
    static func encode(_ selection: Selection) -> String {
        switch selection {
        case .component(let id): "component:\(id)"
        case .wire(let id): "wire:\(id)"
        case .wireSegment(let id, let index): "wireSegment:\(id):\(index)"
        case .probe(let id): "probe:\(id)"
        case .probeMinus(let id): "probeMinus:\(id)"
        case .probeLabel(let id): "probeLabel:\(id)"
        case .currentArrow(let id): "currentArrow:\(id)"
        case .ground(let id): "ground:\(id)"
        case .sense(let id): "sense:\(id)"
        case .senseLabel(let id): "senseLabel:\(id)"
        case .equivalent(let id): "equivalent:\(id)"
        case .textBox(let id): "textBox:\(id)"
        case .excludedArea(let id): "excludedArea:\(id)"
        case .meshMarker(let id): "meshMarker:\(id)"
        case .groupArea(let id): "groupArea:\(id)"
        case .group(let items): items.map(encode).sorted().joined(separator: "|")
        }
    }

    static func decode(_ key: String) -> Selection? {
        if key.contains("|") {
            let items = key.split(separator: "|").compactMap { decode(String($0)) }
            return items.isEmpty ? nil : .group(Set(items))
        }
        let parts = key.split(separator: ":").map(String.init)
        guard parts.count >= 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "component": return .component(id)
        case "wire": return .wire(id)
        case "wireSegment": return parts.count > 2 ? Int(parts[2]).map { .wireSegment(id, $0) } : nil
        case "probe": return .probe(id)
        case "probeMinus": return .probeMinus(id)
        case "probeLabel": return .probeLabel(id)
        case "currentArrow": return .currentArrow(id)
        case "ground": return .ground(id)
        case "sense": return .sense(id)
        case "senseLabel": return .senseLabel(id)
        case "equivalent": return .equivalent(id)
        case "textBox": return .textBox(id)
        case "excludedArea": return .excludedArea(id)
        case "meshMarker": return .meshMarker(id)
        case "groupArea": return .groupArea(id)
        default: return nil
        }
    }
}
