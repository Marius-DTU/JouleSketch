import SwiftUI
import UniformTypeIdentifiers

// MARK: - The way into blocks

/// Shown over the sheet while a block's sub-diagram is edited: the way in
/// from the document's sheet, each step a button back out to it.
struct BlockTrailView: View {
    let editor: CircuitEditor

    var body: some View {
        let trail = editor.blockTrail
        HStack(spacing: 6) {
            Button("Tilbage", systemImage: "chevron.backward") { editor.leaveBlock() }
                .labelStyle(.iconOnly)
                .help("Gå ud af blokken (Esc)")
            ForEach(Array(trail.enumerated()), id: \.offset) { index, name in
                if index > 0 {
                    Image(systemName: "chevron.forward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if index == trail.count - 1 {
                    Text(name).bold()
                } else {
                    Button(name) { editor.leaveBlock(toLevel: index) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inde i blokken \(trail.last ?? "")")
    }
}

// MARK: - The block library

/// The user's library of blocks: saving the selected block, placing one,
/// and exporting and importing the library as a file.
struct BlockLibraryView: View {
    let editor: CircuitEditor

    @AppStorage(SettingsKey.blockLibrary) private var storage = ""
    @Environment(\.dismiss) private var dismiss
    @State private var isImporting = false
    @State private var export: LibraryFile?
    @State private var message: String?

    private var library: BlockLibrary { BlockLibrary(storageString: storage) }

    private func change(_ update: (inout BlockLibrary) -> Void) {
        var library = self.library
        update(&library)
        storage = library.storageString
    }

    /// The block selected on the sheet, which can be saved in the library.
    private var selectedBlock: LogicGate? {
        guard case .gate(let id)? = editor.selection, let gate = editor.gate(id: id), gate.kind == .block else { return nil }
        return gate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bibliotek")
                .font(.headline)
            if library.entries.isEmpty {
                Text("Biblioteket er tomt. Markér en blok på arket, og tryk på Gem markeret blok – eller importér et bibliotek.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(library.entries) { entry in
                            row(entry)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Button("Gem markeret blok", systemImage: "square.and.arrow.down") {
                    if let selectedBlock {
                        change { $0.add(selectedBlock) }
                        message = "\(selectedBlock.name.isEmpty ? "Blokken" : selectedBlock.name) er gemt i biblioteket."
                    }
                }
                .disabled(selectedBlock == nil)
                Spacer()
                Button("Importér…") { isImporting = true }
                Button("Eksportér…") { export = LibraryFile(data: library.exportData()) }
                    .disabled(library.entries.isEmpty)
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 380)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                message = "Filen kunne ikke læses."
                return
            }
            var library = self.library
            message = library.importFile(data)
            storage = library.storageString
        }
        .fileExporter(
            isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
            document: export,
            contentType: .json,
            defaultFilename: BlockLibrary.exportFileName
        ) { result in
            if case .failure = result { message = "Biblioteket kunne ikke eksporteres." }
            export = nil
        }
    }

    private func row(_ entry: BlockLibrary.Entry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Placér") {
                editor.placeFromLibrary(entry)
                dismiss()
            }
            .help("Klik på arket for at placere blokken")
            Menu("Mere", systemImage: "ellipsis") {
                Button("Eksportér…", systemImage: "square.and.arrow.up") {
                    export = LibraryFile(data: library.exportData(ids: [entry.id]))
                }
                Button("Slet", systemImage: "trash", role: .destructive) {
                    change { $0.remove(id: entry.id) }
                }
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
    }
}

/// An exported library, as a JSON file.
struct LibraryFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
