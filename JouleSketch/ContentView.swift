import SwiftUI

/// The editor for one open circuit document.
struct ContentView: View {
    let editor: CircuitEditor

    @Environment(\.undoManager) private var undoManager
    @State private var showInspector = false
    @State private var showSettings = false
    @State private var showSolverReport = false
    @State private var showMapleExport = false
    @State private var showGuide = false
    /// The truth table panel of a digital sheet.
    @State private var showLogic = false
    @State private var showLibrary = false
    @State private var canvasSize: CGSize = .zero
    /// Space between the tool palette and the window's sides.
    private static let paletteMargin: CGFloat = 16
    @AppStorage(SettingsKey.studyMode) private var studyMode = false
    @AppStorage(SettingsKey.walkthroughSideBySide) private var walkthroughSideBySide = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Whether the walkthrough is shown in a panel beside the sheet. On an
    /// iPhone there is no room, so it is always a window there.
    private var walkthroughDocked: Bool {
        #if os(iOS)
        walkthroughSideBySide && sizeClass != .compact
        #else
        walkthroughSideBySide
        #endif
    }

    /// Whether the truth table panel lies beside the sheet. On an iPhone
    /// there is no room, so it is a window there.
    private var logicDocked: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            if editor.needsModeChoice {
                // A new document starts by choosing analog or digital.
                StartView(editor: editor)
            } else {
                sheet
            }
            if showLogic && logicDocked && editor.isDigital && !editor.needsModeChoice {
                Divider()
                    .ignoresSafeArea(edges: .bottom)
                LogicPanelView(editor: editor) { showLogic = false }
                    .frame(width: 460)
                    .clipped()
                    .ignoresSafeArea(edges: .bottom)
            }
            if showMapleExport && walkthroughDocked && !editor.isDigital {
                Divider()
                    .ignoresSafeArea(edges: .bottom)
                // Follows the drawing as it is edited.
                MapleExportView(circuit: editor.calculationCircuit, isDocked: true) {
                    showMapleExport = false
                }
                .frame(width: 440)
                // Nothing wider may reach past the window's edge.
                .clipped()
                .ignoresSafeArea(edges: .bottom)
            }
        }
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .inspector(isPresented: $showInspector) {
            InspectorView(editor: editor)
        }
        .sheet(isPresented: Binding(
            get: { showMapleExport && !walkthroughDocked },
            // Switching to the panel also closes the window; that must
            // not close the walkthrough.
            set: { if !$0 && !walkthroughDocked { showMapleExport = false } }
        )) {
            // Without what lies in excluded areas.
            MapleExportView(circuit: editor.calculationCircuit)
        }
        .sheet(isPresented: Binding(
            get: { showLogic && !logicDocked && editor.isDigital },
            set: { if !$0 { showLogic = false } }
        )) {
            LogicPanelView(editor: editor, isDocked: false)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Færdig") { showSettings = false }
                        }
                    }
            }
        }
        // The document detects unsaved changes (and autosaves) through
        // the undo actions the editor registers here.
        .onAppear { editor.undoManager = undoManager }
        .onChange(of: undoManager) { editor.undoManager = undoManager }
        #if os(macOS)
        // Open documents share one window as tabs.
        .background { DocumentTabs() }
        #endif
        // Outermost, so the items belong to the document's own toolbar.
        .toolbar { toolbarContent }
    }

    /// The drawing sheet with its tool palette.
    private var sheet: some View {
        SchematicCanvas(editor: editor)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                // Drawing mode swaps the tools for the pen's colors and sizes.
                if editor.isDrawing {
                    PenPalette(editor: editor)
                        .padding(.bottom, 12)
                        .padding(.horizontal)
                } else {
                    ToolPalette(editor: editor, availableWidth: max(0, canvasSize.width - 2 * Self.paletteMargin))
                        .padding(.bottom, 12)
                        .padding(.horizontal, Self.paletteMargin)
                }
            }
            .overlay(alignment: .top) {
                // Inside a block: the way back out.
                if editor.isInsideBlock {
                    BlockTrailView(editor: editor)
                        .padding(.top, 10)
                }
            }
            // The palette tells the sheet where it is, in the sheet's coordinates.
            .coordinateSpace(.named(ToolPalette.sheetSpace))
            .sheet(isPresented: $showGuide) {
                UserGuideView()
            }
    }

    private var canvasCenter: CGPoint {
        CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editor.needsModeChoice {
            ToolbarItem {
                Button("Sådan bruger du JouleSketch", systemImage: "info.circle") {
                    showGuide = true
                }
                .sheet(isPresented: $showGuide) {
                    UserGuideView()
                }
            }
        } else {
            sheetToolbar
        }
    }

    @ToolbarContentBuilder
    private var sheetToolbar: some ToolbarContent {
        ToolbarItemGroup {
            // ⌘Z and ⇧⌘Z come from the system's Edit menu in document apps.
            Button("Fortryd", systemImage: "arrow.uturn.backward") { editor.undo() }
                .disabled(!editor.canUndo)
            Button("Gentag", systemImage: "arrow.uturn.forward") { editor.redo() }
                .disabled(!editor.canRedo)
        }

        if editor.isDigital {
            ToolbarItem {
                Toggle("Sandhedstabel", systemImage: "tablecells", isOn: $showLogic)
                    .help("Sandhedstabel og Karnaugh-kort for kredsløbet, og lommeregneren, der finder de gates, en sandhedstabel kræver")
            }
            ToolbarItem {
                Button("Bibliotek", systemImage: "books.vertical") { showLibrary.toggle() }
                    .help("Dine gemte blokke: placér, gem, eksportér og importér")
                    .popover(isPresented: $showLibrary) {
                        BlockLibraryView(editor: editor)
                    }
            }
        } else {
            analogToolbar
        }

        ToolbarItem {
            // Highlighted while drawing mode is on.
            Toggle("Tegn", systemImage: "pencil", isOn: Binding(
                get: { editor.isDrawing },
                set: { editor.isDrawing = $0 }
            ))
            .help("Tegn frit på siden (skjuler værktøjerne)")
        }

        ToolbarItemGroup {
            Button("Slet", systemImage: "trash") { editor.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(editor.selection == nil)

            Menu("Visning", systemImage: "ellipsis") {
                Button("Zoom ind", systemImage: "plus.magnifyingglass") {
                    editor.zoom(by: 1.25, around: canvasCenter)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Zoom ud", systemImage: "minus.magnifyingglass") {
                    editor.zoom(by: 0.8, around: canvasCenter)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Nulstil visning", systemImage: "arrow.counterclockwise") {
                    editor.resetView()
                }
                .keyboardShortcut("0", modifiers: .command)
                if !editor.isDigital {
                    Divider()
                    // Also here, since the switch in the toolbar can't go into
                    // the overflow menu on narrow screens.
                    Toggle("Study mode", systemImage: "graduationcap", isOn: $studyMode)
                }
                Divider()
                Button("Ryd tegning", systemImage: "xmark.bin", role: .destructive) {
                    editor.clearAll()
                }
                Divider()
                Button("Sådan bruger du JouleSketch", systemImage: "info.circle") {
                    showGuide = true
                }
                #if os(macOS)
                SettingsLink {
                    Label("Indstillinger…", systemImage: "gearshape")
                }
                #else
                Button("Indstillinger", systemImage: "gearshape") {
                    showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
                #endif
            }

            Button("Egenskaber", systemImage: "sidebar.trailing") {
                showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    /// Study mode, the calculation report and the Maple output of an analog sheet.
    @ToolbarContentBuilder
    private var analogToolbar: some ToolbarContent {
        ToolbarItem {
            HStack(spacing: 6) {
                Text("Study mode")
                    .font(.callout)
                Toggle("Study mode", isOn: $studyMode)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
            }
            .help("Skjuler de beregnede værdier, så du selv kan regne dem ud")
        }

        ToolbarItem {
            Button {
                showSolverReport.toggle()
            } label: {
                Label("Beregning – hvad mangler?", systemImage: CircuitSolution.symbol(for: editor.solution))
            }
            .help("Vis hvad der er beregnet, og hvad der mangler")
            .popover(isPresented: $showSolverReport) {
                SolverReportView(solution: editor.solution)
            }
        }

        ToolbarItem {
            Button("Maple-output", systemImage: "function") {
                showMapleExport.toggle()
            }
            // Only offered once everything unknown on the sheet can be computed.
            .disabled(!editor.solution.isComplete)
            .help(editor.solution.isComplete
                  ? "Knudepunktsmetoden som Maple-kode, klar til at kopiere"
                  : "Maple-output kræver, at alle ukendte værdier kan beregnes – se Beregning")
        }
    }
}

#Preview {
    NavigationStack {
        ContentView(editor: CircuitEditor())
    }
}

#Preview("Eksempel") {
    let editor = CircuitEditor()
    editor.addComponent(.voltageSource, from: GridPoint(x: 4, y: 14), to: GridPoint(x: 4, y: 8))
    editor.addWire(from: GridPoint(x: 4, y: 8), to: GridPoint(x: 8, y: 4))
    editor.addComponent(.resistor, from: GridPoint(x: 8, y: 4), to: GridPoint(x: 12, y: 4))
    editor.updateComponent(id: editor.circuit.components[0].id) { $0.value = 12 }
    editor.updateComponent(id: editor.circuit.components[1].id) { $0.value = 4700 }
    editor.addWire(from: GridPoint(x: 12, y: 4), to: GridPoint(x: 18, y: 4))
    editor.addComponent(.resistor, from: GridPoint(x: 18, y: 4), to: GridPoint(x: 18, y: 10))
    editor.addComponent(.currentSource, from: GridPoint(x: 14, y: 14), to: GridPoint(x: 14, y: 4))
    editor.updateComponent(id: editor.circuit.components[3].id) { $0.value = 0.001 }
    editor.addWire(from: GridPoint(x: 18, y: 10), to: GridPoint(x: 18, y: 14))
    editor.addWire(from: GridPoint(x: 18, y: 14), to: GridPoint(x: 4, y: 14))
    editor.addProbe(at: GridPoint(x: 14, y: 4))
    editor.addGround(at: GridPoint(x: 4, y: 14))
    editor.addProbe(at: GridPoint(x: 8, y: 4))
    editor.addCurrentArrow(near: CGPoint(x: 18 * 20, y: 12 * 20), tolerance: 12, direction: nil)
    editor.updateCurrentArrow(id: editor.circuit.currents[0].id) { $0.value = 0.002 }
    editor.addCurrentArrow(near: CGPoint(x: 10 * 20, y: 14 * 20), tolerance: 12, direction: CGPoint(x: -20, y: 0))
    editor.tool = .select
    return NavigationStack {
        ContentView(editor: editor)
    }
}

#Preview("Styrede kilder") {
    let editor = CircuitEditor()
    // Voltage divider: S1 = 12 V, R1 = R2 = 100 Ω.
    editor.addComponent(.voltageSource, from: GridPoint(x: 4, y: 12), to: GridPoint(x: 4, y: 8))
    editor.updateComponent(id: editor.circuit.components[0].id) { $0.value = 12 }
    editor.addWire(from: GridPoint(x: 4, y: 8), to: GridPoint(x: 4, y: 4))
    editor.addWire(from: GridPoint(x: 4, y: 4), to: GridPoint(x: 6, y: 4))
    editor.addComponent(.resistor, from: GridPoint(x: 6, y: 4), to: GridPoint(x: 10, y: 4))
    editor.updateComponent(id: editor.circuit.components[1].id) { $0.value = 100 }
    editor.addWire(from: GridPoint(x: 10, y: 4), to: GridPoint(x: 12, y: 6))
    editor.addComponent(.resistor, from: GridPoint(x: 12, y: 6), to: GridPoint(x: 12, y: 10))
    editor.updateComponent(id: editor.circuit.components[2].id) { $0.value = 100 }
    editor.addWire(from: GridPoint(x: 12, y: 10), to: GridPoint(x: 12, y: 14))
    editor.addWire(from: GridPoint(x: 12, y: 14), to: GridPoint(x: 4, y: 14))
    editor.addWire(from: GridPoint(x: 4, y: 12), to: GridPoint(x: 4, y: 14))
    editor.addGround(at: GridPoint(x: 4, y: 14))
    editor.addProbe(at: GridPoint(x: 12, y: 4))

    // Voltage-controlled voltage source (μ = 2) measuring across R2, driving R3.
    editor.addComponent(.vcvs, from: GridPoint(x: 22, y: 12), to: GridPoint(x: 22, y: 8))
    let vcvs = editor.circuit.components[3]
    editor.updateComponent(id: vcvs.id) { $0.value = 2 }
    for (kind, target) in [(SenseMarker.Kind.plus, GridPoint(x: 12, y: 6)), (.minus, GridPoint(x: 12, y: 10))] {
        guard let marker = editor.circuit.sense(of: vcvs.id, kind) else { continue }
        editor.beginMove()
        editor.move(.sense(marker.id), by: target - marker.gridPoint)
        editor.endMove()
    }
    editor.addWire(from: GridPoint(x: 22, y: 8), to: GridPoint(x: 26, y: 8))
    editor.addComponent(.resistor, from: GridPoint(x: 26, y: 8), to: GridPoint(x: 26, y: 12))
    editor.updateComponent(id: editor.circuit.components[4].id) { $0.value = 100 }
    editor.addWire(from: GridPoint(x: 26, y: 12), to: GridPoint(x: 26, y: 14))
    editor.addWire(from: GridPoint(x: 26, y: 14), to: GridPoint(x: 22, y: 14))
    editor.addWire(from: GridPoint(x: 22, y: 12), to: GridPoint(x: 22, y: 14))
    editor.addGround(at: GridPoint(x: 22, y: 14))
    editor.addProbe(at: GridPoint(x: 26, y: 8))

    // Current-controlled current source with its Is marker still beside it.
    editor.addComponent(.cccs, from: GridPoint(x: 34, y: 12), to: GridPoint(x: 34, y: 8))
    editor.tool = .select
    editor.selection = nil
    return NavigationStack {
        ContentView(editor: editor)
    }
    .frame(width: 900, height: 520)
}
