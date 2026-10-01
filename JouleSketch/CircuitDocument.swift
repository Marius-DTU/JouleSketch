import Combine
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A JouleSketch circuit file (.joulesketch). Declared in Info.plist.
    static let jouleSketchCircuit = UTType(exportedAs: "dk.mariuskb.joulesketch.circuit")
}

nonisolated extension CircuitFile {
    static func decode(_ fileWrapper: FileWrapper) throws -> Circuit {
        guard let data = fileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONDecoder().decode(CircuitFile.self, from: data).circuit
    }

    static func encode(_ circuit: Circuit) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(CircuitFile(circuit: circuit))
        return FileWrapper(regularFileWithContents: data)
    }
}

/// A circuit document. The editor holds the circuit and all editing state;
/// the document reads and writes it as JSON.
@available(iOS 27.0, macOS 27.0, *)
@Observable
final class CircuitDocument: Document {
    static let readableContentTypes: [UTType] = [.jouleSketchCircuit]

    let editor = CircuitEditor()

    init() {}

    func reader(configuration: sending ReadConfiguration) -> sending FileWrapperDocumentReader<Circuit> {
        FileWrapperDocumentReader(configuration) { fileWrapper in
            try CircuitFile.decode(fileWrapper)
        }
    }

    @MainActor
    func apply(snapshot: sending Circuit, previous: sending Circuit?) async throws {
        editor.load(snapshot)
    }

    func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<Circuit> {
        FileWrapperDocumentWriter(configuration) { snapshot, _ in
            try CircuitFile.encode(snapshot)
        }
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> sending Circuit {
        editor.circuit
    }
}

/// The same circuit document for systems older than iOS/macOS 27, built on
/// `ReferenceFileDocument`. The editor's registered undo actions mark it as edited.
final class LegacyCircuitDocument: ReferenceFileDocument {
    static let readableContentTypes: [UTType] = [.jouleSketchCircuit]

    let editor = CircuitEditor()

    init() {}

    init(configuration: ReadConfiguration) throws {
        editor.load(try CircuitFile.decode(configuration.file))
    }

    func snapshot(contentType: UTType) throws -> Circuit {
        editor.circuit
    }

    func fileWrapper(snapshot: Circuit, configuration: WriteConfiguration) throws -> FileWrapper {
        try CircuitFile.encode(snapshot)
    }
}
