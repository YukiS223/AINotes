import SwiftUI
import SwiftData
import PencilKit

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Notebook.createdAt, order: .reverse) private var notebooks: [Notebook]

    @State private var selectedNotebook: Notebook?
    @State private var selectedPage: Page?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedNotebook) {
                ForEach(notebooks) { notebook in
                    NavigationLink(value: notebook) {
                        VStack(alignment: .leading) {
                            Text(notebook.title).font(.headline)
                            Text("\(notebook.pages.count) page\(notebook.pages.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteNotebooks)
            }
            .navigationTitle("Notebooks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: addNotebook) {
                        Label("New Notebook", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let notebook = selectedNotebook {
                NotebookView(notebook: notebook)
                    // Force fresh view state (page index etc.) per notebook.
                    // Without this, switching notebooks reuses the old
                    // NotebookView state and the TabView selection can point
                    // at a page index the new notebook doesn't have.
                    .id(notebook.persistentModelID)
            } else {
                ContentUnavailableView(
                    "No Notebook Selected",
                    systemImage: "book.closed",
                    description: Text("Pick a notebook from the sidebar or create a new one.")
                )
            }
        }
    }

    private func addNotebook() {
        let nb = Notebook(title: "Untitled \(notebooks.count + 1)")
        let firstPage = Page(index: 0)
        firstPage.notebook = nb
        nb.pages.append(firstPage)
        context.insert(nb)
        selectedNotebook = nb
    }

    private func deleteNotebooks(at offsets: IndexSet) {
        for index in offsets {
            let nb = notebooks[index]
            // Clear the selection first — the detail view holds a
            // @Bindable to this model and would otherwise keep rendering
            // a deleted object.
            if selectedNotebook === nb { selectedNotebook = nil }
            context.delete(nb)
        }
    }
}

// MARK: - Notebook detail (pages of one notebook)

struct NotebookView: View {
    @Bindable var notebook: Notebook
    @Environment(\.modelContext) private var context

    @State private var currentIndex: Int = 0

    private var sortedPages: [Page] {
        notebook.pages.sorted { $0.index < $1.index }
    }

    var body: some View {
        VStack(spacing: 0) {
            if sortedPages.isEmpty {
                ContentUnavailableView("No Pages", systemImage: "doc")
            } else {
                TabView(selection: $currentIndex) {
                    ForEach(Array(sortedPages.enumerated()), id: \.element.id) { idx, page in
                        PageEditor(page: page)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
            }
        }
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addPage) {
                    Label("Add Page", systemImage: "plus.square")
                }
            }
        }
    }

    private func addPage() {
        let newIndex = (notebook.pages.map(\.index).max() ?? -1) + 1
        let page = Page(index: newIndex)
        page.notebook = notebook
        notebook.pages.append(page)
        currentIndex = sortedPages.count - 1
    }
}

// MARK: - Single page editor

struct PageEditor: View {
    @Bindable var page: Page
    @State private var drawing = PKDrawing()
    @State private var showTutor = false

    // Mark-over-ink layer (existing).
    @State private var aiAnnotations: [AnnotationDTO] = []
    @State private var aiBounds: CGRect = .zero

    // Generative draw layer (new).
    @State private var aiPlayer = AIDrawingPlayer()

    @State private var showGrid = false
    @State private var canvasSize: CGSize = .zero
    @State private var liveSession = LiveSession()

    /// The coordinate space the model addresses with fractional coords.
    /// = the visible viewport. Drawings at x=0.5 land in the middle of
    /// what the user sees on screen, regardless of where their ink is.
    private var canvasBounds: CGRect {
        canvasSize == .zero
            ? CGRect(x: 0, y: 0, width: 820, height: 1100)
            : CGRect(origin: .zero, size: canvasSize)
    }
    private var isLiveSession: Bool {
        if case .live = liveSession.state { return true }
        return false
    }
    private var hasAIContent: Bool {
        !aiAnnotations.isEmpty
            || !aiPlayer.committedDrawing.strokes.isEmpty
            || !aiPlayer.labels.isEmpty
            || aiPlayer.inProgressStroke != nil
    }

    var body: some View {
        ZStack {
            CanvasView(drawing: $drawing)
            // AI ink layer — non-interactive, sits above user canvas.
            AIDrawingCanvas(drawing: aiPlayer.displayedDrawing)
                .allowsHitTesting(false)
            // AI text labels.
            AILabelsOverlay(labels: aiPlayer.labels)
            // Marks-over-ink (snapped circles, arrows, etc.).
            AnnotationOverlay(
                annotations: aiAnnotations,
                snapshotBounds: aiBounds,
                inkBounds: drawing.strokes.map(\.renderBounds)
            )
            if showGrid {
                CoordinateGrid(bounds: canvasBounds)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { canvasSize = geo.size }
                    .onChange(of: geo.size) { _, new in canvasSize = new }
            }
        )
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            loadPersisted()
            // End Session must kill EVERYTHING in flight — including a
            // drawing animation that would otherwise keep painting after
            // the connection is gone. Bind the player directly (not via
            // self.aiPlayer) so the closure stored on liveSession doesn't
            // capture the view struct and its @State storage — that read
            // back as a retain cycle keeping the whole page graph alive.
            let player = aiPlayer
            liveSession.onSessionEnded = { [weak player] in
                player?.cancelPlayback()
            }
        }
        // Page swiped away or notebook closed: end the live session. Its
        // snapshot provider is bound to THIS page, so leaving it running
        // would stream a stale page to the model — and previously also
        // leaked the socket and mic (nothing ever stopped them).
        .onDisappear { liveSession.stop() }
        .onChange(of: drawing) { _, newValue in
            page.drawingData = newValue.dataRepresentation()
            liveSession.noteCanvasChanged()      // NEW
        }
        
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button {
                    showGrid.toggle()
                } label: {
                    Label("Grid", systemImage: showGrid ? "grid.circle.fill" : "grid.circle")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                if hasAIContent {
                    Button {
                        clearAllAIContent()
                    } label: {
                        Label("Clear AI", systemImage: "eraser")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                Button {
                    showTutor = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isLiveSession ? "waveform.circle.fill" : "sparkles")
                            .symbolEffect(.pulse, options: .repeating, isActive: isLiveSession)
                        Text(isLiveSession ? "Live" : "Tutor")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isLiveSession ? Color.red : Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showTutor) {
            TutorPanel(
                captureSnapshot: snapshot,
                canvasBounds: { canvasBounds },
                onDrawAction: { drawings, bounds in
                    guard !drawings.isEmpty else { return }
                    // Student ink: snap targets for "circle the answer"
                    // loops and keep-out zones for explanation text.
                    let ink = drawing.strokes.map(\.renderBounds)
                    // Keep-out for the Grid / Clear AI / Tutor buttons.
                    let controls = CGRect(x: max(bounds.minX, bounds.maxX - 420),
                                          y: bounds.minY, width: 420, height: 64)
                    Task {
                        await aiPlayer.play(actions: drawings, canvasBounds: bounds,
                                            userInk: ink, avoidRects: [controls])
                        saveAIDrawing()
                        // Ship a frame NOW so the model sees its own ink
                        // land instead of waiting for the next heartbeat.
                        liveSession.noteAIDrawingFinished()
                    }
                },
                session: liveSession
            )
            .presentationDetents([.fraction(0.45), .large])   // NEW
            .presentationDragIndicator(.visible)              // NEW

        }
    }

    // MARK: - Persistence

    private func loadPersisted() {
        if !page.drawingData.isEmpty,
           let loaded = try? PKDrawing(data: page.drawingData) {
            drawing = loaded
        }
        if let stored = try? JSONDecoder()
            .decode(StoredAnnotations.self, from: page.annotationData) {
            aiAnnotations = stored.annotations
            aiBounds = stored.bounds
        }
        if !page.aiDrawingData.isEmpty,
           let stored = try? JSONDecoder()
            .decode(StoredAIDrawing.self, from: page.aiDrawingData),
           let pk = try? PKDrawing(data: stored.pkDrawingBytes) {
            aiPlayer.loadCommitted(drawing: pk, labels: stored.labels)
        }
    }

    private func saveAnnotations() {
        let stored = StoredAnnotations(annotations: aiAnnotations, bounds: aiBounds)
        page.annotationData = (try? JSONEncoder().encode(stored)) ?? Data()
    }

    private func saveAIDrawing() {
        let stored = StoredAIDrawing(
            pkDrawingBytes: aiPlayer.committedDrawing.dataRepresentation(),
            labels: aiPlayer.labels
        )
        page.aiDrawingData = (try? JSONEncoder().encode(stored)) ?? Data()
    }

    private func clearAllAIContent() {
        aiAnnotations = []
        aiBounds = .zero
        page.annotationData = Data()
        aiPlayer.clear()
        page.aiDrawingData = Data()
    }

    // MARK: - Snapshot (white bg + user ink + AI ink + AI labels + grid)

    private func snapshot() -> UIImage? {
        let bounds = canvasBounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // Cap the longest side at ~1024 actual pixels. Gemini Live silently
        // DROPS oversized frames (verified against the API: a 3280x4400
        // frame yields "I cannot see your screen", 764x1024 reads fine),
        // and ~1k px is plenty to read handwriting. format.scale = 1 is
        // load-bearing: the default is the device scale, which would
        // multiply the pixel count by 4-9x behind our back.
        let maxSide: CGFloat = 1024
        let scale = min(1.0, maxSide / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        // Render under LIGHT appearance no matter the device theme:
        // PencilKit re-tints ink for dark mode at render time, so a
        // dark-mode user's (visually white) strokes would land white on
        // this white background and the model would see a blank page.
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))

                // User's strokes.
                drawing.image(from: bounds, scale: scale)
                    .draw(in: CGRect(origin: .zero, size: size))

                // AI's strokes (so the model can see what it already drew).
                aiPlayer.committedDrawing.image(from: bounds, scale: scale)
                    .draw(in: CGRect(origin: .zero, size: size))

                // AI text labels.
                for label in aiPlayer.labels {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 16 * scale, weight: .semibold),
                        .foregroundColor: AIPalette.uiColor(label.color)
                    ]
                    let str = NSAttributedString(string: label.text, attributes: attrs)
                    let strSize = str.size()
                    let pos = CGPoint(
                        x: (label.canvasX - bounds.minX) * scale - strSize.width / 2,
                        y: (label.canvasY - bounds.minY) * scale - strSize.height / 2
                    )
                    str.draw(at: pos)
                }

                drawGrid(in: ctx.cgContext, size: size)
            }
        }
        return image
    }

    private func drawGrid(in cg: CGContext, size: CGSize) {
        let steps = 10
        // 14pt in a ~1024px frame — the model must be able to READ the
        // coordinate labels or the grid is dead weight in every frame.
        let font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.systemBlue.withAlphaComponent(0.9)
        ]
        cg.setLineWidth(1)
        for i in 0...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let x = f * size.width
            let y = f * size.height
            let strong = (i % 5 == 0)
            cg.setStrokeColor(UIColor.systemBlue
                .withAlphaComponent(strong ? 0.45 : 0.20).cgColor)
            cg.move(to: CGPoint(x: x, y: 0))
            cg.addLine(to: CGPoint(x: x, y: size.height))
            cg.move(to: CGPoint(x: 0, y: y))
            cg.addLine(to: CGPoint(x: size.width, y: y))
            cg.strokePath()
            let label = String(format: "%.1f", Double(f))
            (label as NSString).draw(at: CGPoint(x: x + 2, y: 2),
                                     withAttributes: labelAttrs)
            (label as NSString).draw(at: CGPoint(x: 2, y: y + 2),
                                     withAttributes: labelAttrs)
        }
    }
}

private struct CoordinateGrid: View {
    let bounds: CGRect
    var body: some View {
        Canvas { ctx, _ in
            guard bounds.width > 0, bounds.height > 0 else { return }
            let steps = 10
            for i in 0...steps {
                let f = CGFloat(i) / CGFloat(steps)
                let strong = (i % 5 == 0)
                let col = Color.blue.opacity(strong ? 0.45 : 0.20)
                let x = bounds.minX + f * bounds.width
                let y = bounds.minY + f * bounds.height
                var v = Path()
                v.move(to: CGPoint(x: x, y: bounds.minY))
                v.addLine(to: CGPoint(x: x, y: bounds.maxY))
                ctx.stroke(v, with: .color(col), lineWidth: 1)
                var h = Path()
                h.move(to: CGPoint(x: bounds.minX, y: y))
                h.addLine(to: CGPoint(x: bounds.maxX, y: y))
                ctx.stroke(h, with: .color(col), lineWidth: 1)
                let label = String(format: "%.1f", Double(f))
                ctx.draw(Text(label).font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.blue),
                         at: CGPoint(x: x + 8, y: bounds.minY + 8),
                         anchor: .topLeading)
                ctx.draw(Text(label).font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.blue),
                         at: CGPoint(x: bounds.minX + 8, y: y + 8),
                         anchor: .topLeading)
            }
        }
        .allowsHitTesting(false)
    }
}
