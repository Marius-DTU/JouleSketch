import Foundation

/// The user's own library of blocks (modules) for digital sheets: blocks
/// saved with their terminals and sub-diagram, to place again on any sheet,
/// and to export to a file and import on another computer.
///
/// The library is kept with the settings (UserDefaults on the Mac, the
/// browser's storage on the web), not in the documents.
nonisolated struct BlockLibrary: Codable, Hashable {
    nonisolated struct Entry: Identifiable, Codable, Hashable {
        var id = UUID()
        /// The block as placed: its name, terminals and sub-diagram, at
        /// (0, 0) and not turned.
        var block: LogicGate

        var name: String { block.name.isEmpty ? "Blok" : block.name }

        /// "8 indgange, 5 udgange", for lists.
        var summary: String {
            let inputs = block.inputOffsets.count, outputs = block.blockOutputRows.count
            let contents = block.subcircuit.map { $0.gates.contains { $0.kind != .input && $0.kind != .output } } == true ? "" : " · intet indhold"
            return "\(inputs) \(inputs == 1 ? "indgang" : "indgange"), \(outputs) \(outputs == 1 ? "udgang" : "udgange")" + contents
        }
    }

    var entries: [Entry] = []

    init() {}

    /// What an exported file says it is, so other JSON isn't taken for a library.
    static let format = "joulesketch-library"
    static let version = 1
    /// The name an exported library file gets.
    static let exportFileName = "JouleSketch-bibliotek.json"

    private enum CodingKeys: String, CodingKey {
        case format, version, entries
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decodeIfPresent(String.self, forKey: .format)
        guard format == nil || format == Self.format else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: container, debugDescription: "Ikke et JouleSketch-bibliotek")
        }
        entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.format, forKey: .format)
        try container.encode(Self.version, forKey: .version)
        try container.encode(entries, forKey: .entries)
    }

    // MARK: Keeping it with the settings

    init(storageString: String) {
        if let library = try? Self.decode(Data(storageString.utf8)) { self = library }
    }

    var storageString: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Building it

    /// Saves a block in the library as it is now, at (0, 0) and not turned.
    /// A block saved before with the same name is replaced. Returns the entry.
    @discardableResult
    mutating func add(_ gate: LogicGate) -> Entry {
        var block = gate
        block.id = UUID()
        block.position = GridPoint(x: 0, y: 0)
        block.rotation = 0
        if let index = entries.firstIndex(where: { $0.block.name == block.name }) {
            entries[index].block = block
            return entries[index]
        }
        let entry = Entry(block: block)
        entries.append(entry)
        entries.sort { LogicNetwork.nameOrder($0.name, $1.name) }
        return entry
    }

    mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func entry(id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    // MARK: Export and import

    /// The library, or some of its entries, as a file to export.
    func exportData(ids: Set<UUID>? = nil) -> Data {
        var exported = self
        if let ids { exported.entries = entries.filter { ids.contains($0.id) } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(exported)) ?? Data()
    }

    /// Reads an exported library.
    static func decode(_ data: Data) throws -> BlockLibrary {
        try JSONDecoder().decode(BlockLibrary.self, from: data)
    }

    /// Adds the blocks of an imported library; blocks with the same name are
    /// replaced by the imported ones. Returns how many were imported.
    @discardableResult
    mutating func importing(_ other: BlockLibrary) -> Int {
        for entry in other.entries { add(entry.block) }
        return other.entries.count
    }

    /// Imports an exported library file. Returns a message for the user.
    mutating func importFile(_ data: Data) -> String {
        guard let other = try? Self.decode(data) else {
            return "Filen er ikke et JouleSketch-bibliotek."
        }
        let count = importing(other)
        return count == 1 ? "1 blok er importeret." : "\(count) blokke er importeret."
    }
}
