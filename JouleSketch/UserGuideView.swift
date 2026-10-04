import SwiftUI

/// The guide to the program, opened from the ⋯ Visning menu. Its
/// text comes from the shared `UserGuide`, like the web version's.
struct UserGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.keyBindings) private var keyBindingsStorage = ""
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var sections: [GuideSection] {
        #if os(iOS)
        let platform = GuidePlatform.touch
        #else
        let platform = GuidePlatform.mac
        #endif
        return UserGuide.sections(for: platform, keys: KeyBindings(storageString: keyBindingsStorage))
    }

    /// Whether there's room for the table of contents beside the text.
    private var showsContents: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    var body: some View {
        let sections = sections
        NavigationStack {
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    if showsContents {
                        contents(sections, proxy: proxy)
                        Divider()
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(sections) { section in
                                sectionView(section)
                                    .id(section.id)
                            }
                        }
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle("Sådan bruger du JouleSketch")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Færdig") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 680)
        #endif
    }

    /// The section titles; clicking one scrolls to it.
    private func contents(_ sections: [GuideSection], proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Indhold")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                ForEach(sections) { section in
                    Button {
                        withAnimation { proxy.scrollTo(section.id, anchor: .top) }
                    } label: {
                        Text(section.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: 220)
    }

    private func sectionView(_ section: GuideSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.title2.bold())
            ForEach(section.blocks.indices, id: \.self) { index in
                blockView(section.blocks[index])
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: GuideBlock) -> some View {
        switch block {
        case .text(let text):
            styled(text)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        styled(items[index])
                    }
                }
            }
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(rows.indices, id: \.self) { index in
                    GridRow {
                        Text(rows[index].key)
                            .font(.callout.monospaced().weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        styled(rows[index].action)
                    }
                }
            }
            .padding(.leading, 4)
        case .tip(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.yellow)
                styled(text)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Text with its **bold** parts in bold.
    private func styled(_ text: String) -> some View {
        var result = AttributedString()
        for run in UserGuide.runs(text) {
            var part = AttributedString(run.text)
            if run.bold { part.inlinePresentationIntent = .stronglyEmphasized }
            result += part
        }
        return Text(result)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

#Preview {
    UserGuideView()
}
