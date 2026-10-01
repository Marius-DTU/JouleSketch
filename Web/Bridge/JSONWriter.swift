#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Writes JSON text directly, which is much faster than `JSONEncoder` for the
/// scene that's sent to the page on every pointer movement.
final class JSONWriter {
    private(set) var text = ""
    /// Whether the next value in the current object or array needs a comma first.
    private var needsComma = false

    private func separate() {
        if needsComma { text += "," }
        needsComma = true
    }

    func key(_ name: String) {
        separate()
        string(name)
        text += ":"
        needsComma = false
    }

    func object(_ body: () -> Void) {
        separate()
        text += "{"
        needsComma = false
        body()
        text += "}"
        needsComma = true
    }

    func array<Element>(_ elements: [Element], _ body: (Element) -> Void) {
        separate()
        text += "["
        needsComma = false
        for element in elements { body(element) }
        text += "]"
        needsComma = true
    }

    func value(_ value: String?) {
        separate()
        if let value { string(value) } else { text += "null" }
    }

    func value(_ value: Double) {
        separate()
        number(value)
    }

    func value(_ value: Bool) {
        separate()
        text += value ? "true" : "false"
    }

    func field(_ name: String, _ value: String?) {
        key(name)
        self.value(value)
    }

    func field(_ name: String, _ value: Double) {
        key(name)
        self.value(value)
    }

    func field(_ name: String, _ value: Int) {
        key(name)
        self.value(Double(value))
    }

    func field(_ name: String, _ value: Bool) {
        key(name)
        self.value(value)
    }

    /// Numbers with at most two decimals (screen points), and 0 for NaN and infinity.
    func number(_ value: Double) {
        guard value.isFinite else {
            text += "0"
            return
        }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            text += String(Int(rounded))
        } else {
            text += String(rounded)
        }
    }

    private func string(_ value: String) {
        text += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case _ where scalar.value < 0x20:
                text += "\\u" + String(repeating: "0", count: 4 - String(scalar.value, radix: 16).count) + String(scalar.value, radix: 16)
            default: text.unicodeScalars.append(scalar)
            }
        }
        text += "\""
    }
}

/// The scene as compact JSON for `Web/app/src/render.ts`.
///
/// Each primitive is an object with `t`: "s" (stroke), "f" (fill), "x" (text)
/// or "d" (dots). Paths are flat number arrays of operations: 0 x y (move),
/// 1 x y (line), 2 (close), 3 x y w h (ellipse), 4 x y w h (rectangle),
/// 5 x y w h r (rounded rectangle). Colors are [r, g, b, a] from 0 to 1.
enum SceneJSON {
    static func encode(_ primitives: [ScenePrimitive]) -> String {
        let json = JSONWriter()
        json.array(primitives) { primitive in
            json.object {
                switch primitive {
                case .stroke(let ops, let color, let width, let dash, let roundCap):
                    json.field("t", "s")
                    path(of: ops, into: json)
                    self.color(color, into: json)
                    json.field("w", Double(width))
                    if !dash.isEmpty {
                        json.key("d")
                        json.array(dash) { json.value(Double($0)) }
                    }
                    if !roundCap { json.field("b", true) }
                case .fill(let ops, let color, let evenOdd):
                    json.field("t", "f")
                    path(of: ops, into: json)
                    self.color(color, into: json)
                    if evenOdd { json.field("e", true) }
                case .text(let runs, let point, let anchor):
                    json.field("t", "x")
                    json.field("x", Double(point.x))
                    json.field("y", Double(point.y))
                    json.field("ax", Double(anchor.x))
                    json.field("ay", Double(anchor.y))
                    json.key("r")
                    json.array(runs) { run in
                        json.object {
                            json.field("s", run.text)
                            json.field("z", Double(run.size))
                            json.field("w", run.weight)
                            if run.italic { json.field("i", true) }
                            if run.baseline != 0 { json.field("o", Double(run.baseline)) }
                            self.color(run.color, into: json)
                        }
                    }
                case .dots(let points, let size, let color):
                    json.field("t", "d")
                    json.key("p")
                    json.array(points) { point in
                        json.value(Double(point.x))
                        json.value(Double(point.y))
                    }
                    json.field("z", Double(size))
                    self.color(color, into: json)
                }
            }
        }
        return json.text
    }

    private static func color(_ color: SceneColor, into json: JSONWriter) {
        json.key("c")
        json.array([color.r, color.g, color.b, color.a]) { json.value($0) }
    }

    private static func path(of ops: [PathOp], into json: JSONWriter) {
        var numbers: [Double] = []
        for op in ops {
            switch op {
            case .move(let p): numbers += [0, p.x, p.y]
            case .line(let p): numbers += [1, p.x, p.y]
            case .close: numbers.append(2)
            case .ellipse(let r): numbers += [3, r.minX, r.minY, r.width, r.height]
            case .rect(let r): numbers += [4, r.minX, r.minY, r.width, r.height]
            case .roundedRect(let r, let radius): numbers += [5, r.minX, r.minY, r.width, r.height, radius]
            }
        }
        json.key("p")
        json.array(numbers) { json.value($0) }
    }
}

#if os(WASI)
/// A small undo manager for the web, where Foundation's isn't available.
/// Undoing an action that registers another while undoing records it for
/// redo, as `UndoManager` does.
final class UndoManager {
    private var undoStack: [() -> Void] = []
    private var redoStack: [() -> Void] = []
    private var isUndoing = false
    private var isRedoing = false

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func registerUndo<Target: AnyObject>(withTarget target: Target, handler: @escaping (Target) -> Void) {
        let action = { [weak target] in
            guard let target else { return }
            handler(target)
        }
        if isUndoing {
            redoStack.append(action)
        } else {
            undoStack.append(action)
            // A new change (not a redo) forgets what could be redone.
            if !isRedoing { redoStack.removeAll() }
        }
    }

    func undo() {
        guard let action = undoStack.popLast() else { return }
        isUndoing = true
        action()
        isUndoing = false
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        isRedoing = true
        action()
        isRedoing = false
    }

    func removeAllActions() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
#endif
