import SwiftUI
import SwiftData
import PencilKit
import PhotosUI
import UniformTypeIdentifiers

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
    @State private var showFileImporter = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importFailure: ImportFailure?

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
                        PageEditor(page: page, isActive: currentIndex == idx)
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
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("PDF or Image from Files", systemImage: "folder")
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Image from Photos", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(isImporting)

                Button(action: addPage) {
                    Label("Add Page", systemImage: "plus.square")
                }
                .disabled(isImporting)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .image],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            guard !isImporting else {
                selectedPhoto = nil
                return
            }
            isImporting = true
            Task { await importPhoto(item) }
        }
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("Importing pages…")
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .alert(item: $importFailure) { failure in
            Alert(
                title: Text("Couldn’t Import"),
                message: Text(failure.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func addPage() {
        let newIndex = (notebook.pages.map(\.index).max() ?? -1) + 1
        let page = Page(index: newIndex)
        page.notebook = notebook
        notebook.pages.append(page)
        currentIndex = sortedPages.count - 1
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty, !isImporting else { return }
            isImporting = true
            Task {
                await Task.yield()
                defer { isImporting = false }

                var firstImportedPage: Page?
                var failures: [String] = []
                for url in urls {
                    do {
                        try await PageBackgroundImporter.importFile(at: url) { background in
                            let page = try appendImportedPage(background)
                            if firstImportedPage == nil { firstImportedPage = page }
                        }
                    } catch {
                        failures.append(error.localizedDescription)
                    }
                }

                selectImportedPage(firstImportedPage)
                if !failures.isEmpty {
                    importFailure = ImportFailure(message: failures.joined(separator: "\n"))
                }
            }
        case .failure(let error):
            // Cancelling the system picker is not an import failure worth
            // interrupting the user with.
            if (error as NSError).code != NSUserCancelledError {
                importFailure = ImportFailure(message: error.localizedDescription)
            }
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        defer {
            isImporting = false
            selectedPhoto = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PageBackgroundImportError.unreadableFile("Selected photo")
            }
            let contentType = item.supportedContentTypes.first?.identifier
                ?? UTType.image.identifier
            let imported = try await Task.detached(priority: .userInitiated) {
                try PageBackgroundImporter.loadImage(
                    data: data,
                    sourceName: "Photo",
                    sourceContentType: contentType
                )
            }.value
            selectImportedPage(try appendImportedPage(imported))
        } catch {
            importFailure = ImportFailure(message: error.localizedDescription)
        }
    }

    private func appendImportedPage(_ background: ImportedPageBackground) throws -> Page {
        // A brand-new notebook starts with one blank page. Reuse it for the
        // first import instead of leaving an unexplained empty sheet in
        // front of the document.
        if notebook.pages.count == 1,
           let blank = notebook.pages.first,
           isBlank(blank) {
            apply(background, to: blank)
            do {
                try context.save()
                return blank
            } catch {
                clearBackground(on: blank)
                throw error
            }
        }

        let nextIndex = (notebook.pages.map(\.index).max() ?? -1) + 1
        let page = Page(index: nextIndex)
        apply(background, to: page)
        page.notebook = notebook
        notebook.pages.append(page)
        context.insert(page)
        do {
            try context.save()
            return page
        } catch {
            notebook.pages.removeAll { $0 === page }
            context.delete(page)
            throw error
        }
    }

    private func selectImportedPage(_ page: Page?) {
        if let page,
           let position = sortedPages.firstIndex(where: { $0 === page }) {
            currentIndex = position
        }
    }

    private func apply(_ background: ImportedPageBackground, to page: Page) {
        page.backgroundData = background.data
        page.backgroundSourceName = background.sourceName
        page.backgroundContentType = background.contentType
        page.backgroundPageNumber = background.pageNumber
    }

    private func clearBackground(on page: Page) {
        page.backgroundData = nil
        page.backgroundSourceName = nil
        page.backgroundContentType = nil
        page.backgroundPageNumber = nil
    }

    private func isBlank(_ page: Page) -> Bool {
        page.drawingData.isEmpty
            && page.chatData.isEmpty
            && page.aiDrawingData.isEmpty
            && page.annotationData.isEmpty
            && (page.textLayerData?.isEmpty ?? true)
            && page.backgroundData == nil
    }
}

private struct ImportFailure: Identifiable {
    let id = UUID()
    let message: String
}

// MARK: - Single page editor

struct PageEditor: View {
    @Bindable var page: Page
    let isActive: Bool
    @State private var drawing = PKDrawing()
    @State private var showTutor = false
    @State private var toolMode: CanvasToolMode = .ink
    @State private var canvasController = CanvasController()
    @State private var textStore = PageTextStore()
    @State private var backgroundImage: UIImage?
    @State private var backgroundAvoidRects: [CGRect] = []
    @State private var referenceCanvasSize: CGSize?
    @State private var showTextEditor = false
    @State private var draftText = ""
    @State private var editingTextID: UUID?
    @State private var pendingTextPoint: CGPoint?
    @State private var hasLoadedPersisted = false
    @State private var showToolCustomization = false
    @State private var showInkSettings = false
    @State private var showEraserSettings = false
    @State private var toolConfiguration = EditorToolConfiguration.shared
    @AppStorage("editor.eraser.width.v1")
    private var eraserWidth = Double(PKEraserTool.EraserType.fixedWidthBitmap.defaultWidth)
    @AppStorage("editor.floatingToolbar.normalizedX.v1")
    private var toolbarNormalizedX = 0.5
    @AppStorage("editor.floatingToolbar.normalizedY.v1")
    private var toolbarNormalizedY = 1.0
    @State private var toolbarSize = CGSize(width: 640, height: 64)
    @State private var toolbarDragStart: CGPoint?
    @State private var transientToolbarCenter: CGPoint?
    @State private var selectedNativeToolID =
        SharedToolPicker.lastInkItemIdentifier ?? EditorPickerItemID.pen
    @State private var lastInkingToolID =
        SharedToolPicker.lastInkItemIdentifier ?? EditorPickerItemID.pen
    @State private var inkColor = Color(uiColor: SharedToolPicker.lastInkTool.color)
    @State private var inkWidths: [String: Double] = {
        var widths: [String: Double] = [
            EditorPickerItemID.pen: 4,
            EditorPickerItemID.pencil: 4,
            EditorPickerItemID.marker: 12
        ]
        if let identifier = SharedToolPicker.lastInkItemIdentifier {
            widths[identifier] = Double(SharedToolPicker.lastInkTool.width)
        }
        return widths
    }()

    // Mark-over-ink layer (existing).
    @State private var aiAnnotations: [AnnotationDTO] = []
    @State private var aiBounds: CGRect = .zero

    // Generative draw layer (new).
    @State private var aiPlayer = AIDrawingPlayer()

    @State private var canvasSize: CGSize = .zero
    @State private var liveSession = LiveSession()

    private var stablePageSize: CGSize {
        if let referenceCanvasSize { return referenceCanvasSize }
        if canvasSize.width > 0, canvasSize.height > 0 { return canvasSize }
        return CGSize(width: 820, height: 1100)
    }
    /// PencilKit and every overlay share this persistent logical coordinate
    /// space. The whole page is scaled for display when the window changes;
    /// its stroke coordinates never move underneath the imported paper.
    private var canvasBounds: CGRect {
        CGRect(origin: .zero, size: stablePageSize)
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
        GeometryReader { geo in
            let viewportSize = geo.size
            let pageSize = referenceCanvasSize ?? validPageSize(viewportSize)
            let scale = pageDisplayScale(pageSize: pageSize, viewportSize: viewportSize)
            let displayedSize = CGSize(width: pageSize.width * scale,
                                       height: pageSize.height * scale)

            ZStack(alignment: .topLeading) {
                Color(uiColor: .systemGroupedBackground)
                pageSurface(size: pageSize)
                    .frame(width: pageSize.width, height: pageSize.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(
                        x: max(0, (viewportSize.width - displayedSize.width) / 2),
                        y: max(0, (viewportSize.height - displayedSize.height) / 2)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)

                if isActive {
                    EditorInkToolbar(
                        enabledIDs: toolConfiguration.enabledIDs,
                        activeToolID: activeEditorToolID,
                        inkColor: inkColor,
                        onUndo: canvasController.undo,
                        onRedo: canvasController.redo,
                        onSelectTool: selectEditorTool,
                        onSelectColor: selectInkColor,
                        onShowToolSettings: openToolSettings,
                        onCustomize: { showToolCustomization = true },
                        onMoveChanged: { translation in
                            updateToolbarDrag(translation, viewportSize: viewportSize)
                        },
                        onMoveEnded: { translation in
                            finishToolbarDrag(translation, viewportSize: viewportSize)
                        }
                    )
                    // An explicit proposal is required here: a horizontal
                    // ScrollView reports its full content as an ideal width,
                    // which would otherwise stretch the floating capsule to
                    // both screen edges before it becomes scrollable.
                    .frame(width: max(1, min(760, viewportSize.width - 24)))
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { newSize in
                        guard newSize.width > 0, newSize.height > 0 else { return }
                        toolbarSize = newSize
                    }
                    .position(toolbarCenter(in: viewportSize))
                    .zIndex(10)
                }
            }
            .clipped()
            .onAppear { updateCanvasSize(viewportSize) }
            .onChange(of: viewportSize) { _, new in updateCanvasSize(new) }
        }
        .toolbar {
            if isActive {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if hasSeparatedEditorTools {
                        Menu {
                            if toolConfiguration.isEnabled(EditorPickerItemID.lasso)
                                || toolConfiguration.isEnabled(EditorPickerItemID.text) {
                                Section("Editing") {
                                    if toolConfiguration.isEnabled(EditorPickerItemID.lasso) {
                                        Button {
                                            toolMode = .selection
                                        } label: {
                                            Label("Selection", systemImage: "lasso")
                                        }
                                    }
                                    if toolConfiguration.isEnabled(EditorPickerItemID.text) {
                                        Button {
                                            toolMode = .text
                                        } label: {
                                            Label("Text", systemImage: "character.cursor.ibeam")
                                        }
                                    }
                                }
                            }

                            let enabledShapes = ShapeKind.allCases.filter {
                                toolConfiguration.isEnabled(EditorPickerItemID.shape($0))
                            }
                            if !enabledShapes.isEmpty {
                                Section("Shapes") {
                                    ForEach(enabledShapes) { kind in
                                        Button {
                                            toolMode = .shape(kind)
                                        } label: {
                                            Label(kind.title, systemImage: kind.symbolName)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Selection, Text, and Shapes",
                                  systemImage: separatedToolSymbol)
                        }
                    }
                    if hasAIContent {
                        Button("Clear AI", systemImage: "eraser") {
                            clearAllAIContent()
                        }
                    }
                    Button(isLiveSession ? "Live" : "Tutor",
                           systemImage: isLiveSession
                               ? "waveform.circle.fill"
                               : "sparkles") {
                        showTutor = true
                    }
                    .tint(isLiveSession ? .red : nil)
                }
            }
        }
        .onAppear {
            canvasController.attachTextEditor(textStore)
            loadPersisted()
            hasLoadedPersisted = true
            initializeReferenceCanvasIfNeeded(minimumSize: canvasSize)
            refreshBackgroundAvoidRects()
            normalizeNativeToolSelection()
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
        .onDisappear {
            textStore.deselectText()
            liveSession.stop()
        }
        .onChange(of: drawing) { _, newValue in
            page.drawingData = newValue.dataRepresentation()
            liveSession.noteCanvasChanged()      // NEW
        }
        .onChange(of: page.backgroundData) { _, newValue in
            backgroundImage = newValue.flatMap(UIImage.init(data:))
            refreshBackgroundAvoidRects()
            liveSession.noteCanvasChanged()
        }
        .onChange(of: textStore.boxes) { _, _ in
            page.textLayerData = textStore.encodedData()
            liveSession.noteCanvasChanged()
        }
        .onChange(of: toolMode) { _, newMode in
            if newMode != .selection && newMode != .text {
                textStore.deselectText()
            }
        }
        .onChange(of: toolConfiguration.enabledIDs) { _, enabledIDs in
            switch toolMode {
            case .selection where !enabledIDs.contains(EditorPickerItemID.lasso):
                toolMode = .ink
            case .text where !enabledIDs.contains(EditorPickerItemID.text):
                toolMode = .ink
            case .shape(let kind)
                where !enabledIDs.contains(EditorPickerItemID.shape(kind)):
                toolMode = .ink
            case .ink, .selection, .text, .shape:
                break
            }
            normalizeNativeToolSelection()
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
                        + textStore.boxes.map { $0.frame.cgRect.insetBy(dx: -8, dy: -8) }
                    Task {
                        await aiPlayer.play(actions: drawings, canvasBounds: bounds,
                                            userInk: ink,
                                            avoidRects: backgroundAvoidRects
                                                + legacyAnnotationAvoidRects
                                                + floatingToolbarAvoidRects)
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
        .sheet(isPresented: $showToolCustomization) {
            EditorToolCustomizationView(configuration: toolConfiguration)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showInkSettings) {
            EditorInkSettingsView(
                color: inkColorBinding,
                width: inkWidthBinding
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEraserSettings) {
            EditorEraserSettingsView(width: $eraserWidth)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert(editingTextID == nil ? "Add Text" : "Edit Text",
               isPresented: $showTextEditor) {
            TextField("Text", text: $draftText)
            Button("Cancel", role: .cancel) { resetTextEditor() }
            Button(editingTextID == nil ? "Add" : "Save") { commitTextEditor() }
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Text remains editable and can be moved or copied with Selection.")
        }
    }

    @ViewBuilder
    private func pageSurface(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white
            if let backgroundImage {
                Image(uiImage: backgroundImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }
            CanvasView(
                drawing: $drawing,
                toolMode: $toolMode,
                controller: canvasController,
                enabledToolIDs: toolConfiguration.enabledIDs.intersection(
                    EditorPickerItemID.nativePickerIDs
                ),
                selectedNativeToolID: selectedNativeToolID,
                inkColor: UIColor(inkColor),
                inkWidth: selectedToolWidth,
                isActive: isActive,
                onRequestToolCustomization: {
                    showToolCustomization = true
                }
            )
            if toolMode == .text {
                TextPlacementOverlay(onTap: beginAddingText(at:))
            }
            NoteTextBoxesOverlay(
                store: textStore,
                mode: toolMode,
                onEdit: beginEditingText(id:)
            )
            if let shapeKind = toolMode.shapeKind {
                ShapeDrawingOverlay(
                    kind: shapeKind,
                    style: canvasController.currentShapeStyle(),
                    onCommit: canvasController.append(strokes:)
                )
            }
            AIDrawingCanvas(drawing: aiPlayer.displayedDrawing)
                .allowsHitTesting(false)
            AILabelsOverlay(labels: aiPlayer.labels)
            AnnotationOverlay(
                annotations: aiAnnotations,
                snapshotBounds: aiBounds,
                inkBounds: drawing.strokes.map(\.renderBounds)
            )
        }
        .contentShape(Rectangle())
    }

    // MARK: - Persistence

    private func loadPersisted() {
        if let width = page.referenceCanvasWidth,
           let height = page.referenceCanvasHeight,
           width > 0, height > 0 {
            referenceCanvasSize = CGSize(width: width, height: height)
            textStore.setPageBounds(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let data = page.backgroundData {
            backgroundImage = UIImage(data: data)
        } else {
            backgroundImage = nil
        }
        if !page.drawingData.isEmpty,
           let loaded = try? PKDrawing(data: page.drawingData) {
            drawing = loaded
        }
        textStore.load(from: page.textLayerData)
        if let stored = try? JSONDecoder()
            .decode(StoredAnnotations.self, from: page.annotationData) {
            aiAnnotations = stored.annotations
            aiBounds = stored.bounds
        }
        if !page.aiDrawingData.isEmpty,
           let stored = try? JSONDecoder()
            .decode(StoredAIDrawing.self, from: page.aiDrawingData),
           let pk = try? PKDrawing(data: stored.pkDrawingBytes) {
            aiPlayer.loadCommitted(
                drawing: pk,
                labels: stored.labels,
                reservedRects: (stored.reservedRects ?? []).map(\.cgRect)
            )
        }
    }

    private func updateCanvasSize(_ newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0 else { return }
        canvasSize = newSize
        if referenceCanvasSize != nil {
            textStore.setPageBounds(canvasBounds)
            return
        }
        guard hasLoadedPersisted else { return }
        initializeReferenceCanvasIfNeeded(minimumSize: newSize)
    }

    private func initializeReferenceCanvasIfNeeded(minimumSize: CGSize) {
        guard referenceCanvasSize == nil,
              minimumSize.width > 0, minimumSize.height > 0 else { return }
        if let width = page.referenceCanvasWidth,
           let height = page.referenceCanvasHeight,
           width > 0, height > 0 {
            referenceCanvasSize = CGSize(width: width, height: height)
            textStore.setPageBounds(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            let referenceSize = legacyContentSize(minimumSize: minimumSize)
            referenceCanvasSize = referenceSize
            page.referenceCanvasWidth = referenceSize.width
            page.referenceCanvasHeight = referenceSize.height
            textStore.setPageBounds(CGRect(origin: .zero, size: referenceSize))
        }
        refreshBackgroundAvoidRects()
    }

    private func refreshBackgroundAvoidRects() {
        guard let backgroundImage else {
            backgroundAvoidRects = []
            return
        }
        backgroundAvoidRects = BackgroundOccupancy.rects(
            for: backgroundImage,
            canvasBounds: canvasBounds
        )
    }

    private func legacyContentSize(minimumSize: CGSize) -> CGSize {
        var contentMaxX: CGFloat = 0
        var contentMaxY: CGFloat = 0

        func include(_ rect: CGRect) {
            guard !rect.isNull, !rect.isInfinite,
                  rect.maxX.isFinite, rect.maxY.isFinite else { return }
            contentMaxX = max(contentMaxX, rect.maxX)
            contentMaxY = max(contentMaxY, rect.maxY)
        }

        include(drawing.bounds)
        include(aiPlayer.committedDrawing.bounds)
        include(aiBounds)
        for label in aiPlayer.labels { include(AILabelLayout.rect(for: label)) }
        for reserved in aiPlayer.reservedRects { include(reserved) }
        for box in textStore.boxes { include(box.frame.cgRect) }

        let margin: CGFloat = 32
        let width = contentMaxX > minimumSize.width
            ? ceil(contentMaxX + margin)
            : minimumSize.width
        let height = contentMaxY > minimumSize.height
            ? ceil(contentMaxY + margin)
            : minimumSize.height
        return CGSize(width: width, height: height)
    }

    private func beginAddingText(at point: CGPoint) {
        editingTextID = nil
        pendingTextPoint = point
        draftText = ""
        showTextEditor = true
    }

    private func beginEditingText(id: UUID) {
        guard let box = textStore.textBox(id: id) else { return }
        editingTextID = id
        pendingTextPoint = nil
        draftText = box.text
        showTextEditor = true
    }

    private func commitTextEditor() {
        if let editingTextID {
            textStore.updateText(id: editingTextID, text: draftText)
        } else if let pendingTextPoint {
            textStore.addText(draftText, centeredAt: pendingTextPoint)
        }
        resetTextEditor()
    }

    private func resetTextEditor() {
        showTextEditor = false
        draftText = ""
        editingTextID = nil
        pendingTextPoint = nil
    }

    private func validPageSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else {
            return CGSize(width: 820, height: 1100)
        }
        return size
    }

    private var hasSeparatedEditorTools: Bool {
        toolConfiguration.isEnabled(EditorPickerItemID.lasso)
            || toolConfiguration.isEnabled(EditorPickerItemID.text)
            || ShapeKind.allCases.contains {
                toolConfiguration.isEnabled(EditorPickerItemID.shape($0))
            }
    }

    // MARK: - Floating toolbar

    private func toolbarCenter(in viewportSize: CGSize) -> CGPoint {
        let stored = CGPoint(
            x: CGFloat(toolbarNormalizedX) * viewportSize.width,
            y: CGFloat(toolbarNormalizedY) * viewportSize.height
        )
        return clampedToolbarCenter(
            transientToolbarCenter ?? stored,
            viewportSize: viewportSize
        )
    }

    private func clampedToolbarCenter(_ proposed: CGPoint,
                                      viewportSize: CGSize) -> CGPoint {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return proposed
        }

        let edgeMargin: CGFloat = 12
        // TabView's page control and the device home indicator occupy this
        // lower strip. The movable toolbar can never be stranded on top of it.
        let bottomNavigationReserve: CGFloat = 68
        let halfWidth = min(toolbarSize.width / 2,
                            max(0, viewportSize.width / 2 - edgeMargin))
        let halfHeight = min(toolbarSize.height / 2,
                             max(0, viewportSize.height / 2 - edgeMargin))
        let minX = edgeMargin + halfWidth
        let maxX = viewportSize.width - edgeMargin - halfWidth
        let minY = edgeMargin + halfHeight
        let maxY = viewportSize.height - bottomNavigationReserve - halfHeight

        return CGPoint(
            x: minX <= maxX
                ? min(maxX, max(minX, proposed.x))
                : viewportSize.width / 2,
            y: minY <= maxY
                ? min(maxY, max(minY, proposed.y))
                : viewportSize.height / 2
        )
    }

    private func updateToolbarDrag(_ translation: CGSize,
                                   viewportSize: CGSize) {
        if toolbarDragStart == nil {
            toolbarDragStart = toolbarCenter(in: viewportSize)
        }
        guard let start = toolbarDragStart else { return }
        transientToolbarCenter = clampedToolbarCenter(
            CGPoint(x: start.x + translation.width,
                    y: start.y + translation.height),
            viewportSize: viewportSize
        )
    }

    private func finishToolbarDrag(_ translation: CGSize,
                                   viewportSize: CGSize) {
        let start = toolbarDragStart ?? toolbarCenter(in: viewportSize)
        let final = clampedToolbarCenter(
            CGPoint(x: start.x + translation.width,
                    y: start.y + translation.height),
            viewportSize: viewportSize
        )
        if viewportSize.width > 0, viewportSize.height > 0 {
            toolbarNormalizedX = Double(final.x / viewportSize.width)
            toolbarNormalizedY = Double(final.y / viewportSize.height)
        }
        transientToolbarCenter = nil
        toolbarDragStart = nil
    }

    /// The toolbar floats above the page, so translate its visible frame back
    /// into the persistent canvas coordinate space for AI collision checks.
    private var floatingToolbarAvoidRects: [CGRect] {
        let viewportSize = canvasSize
        let pageSize = stablePageSize
        guard viewportSize.width > 0, viewportSize.height > 0,
              pageSize.width > 0, pageSize.height > 0 else { return [] }

        let scale = pageDisplayScale(pageSize: pageSize,
                                     viewportSize: viewportSize)
        guard scale > 0 else { return [] }
        let displayedSize = CGSize(width: pageSize.width * scale,
                                   height: pageSize.height * scale)
        let pageOrigin = CGPoint(
            x: max(0, (viewportSize.width - displayedSize.width) / 2),
            y: max(0, (viewportSize.height - displayedSize.height) / 2)
        )
        let pageFrame = CGRect(origin: pageOrigin, size: displayedSize)
        let center = toolbarCenter(in: viewportSize)
        let toolbarFrame = CGRect(
            x: center.x - toolbarSize.width / 2,
            y: center.y - toolbarSize.height / 2,
            width: toolbarSize.width,
            height: toolbarSize.height
        ).insetBy(dx: -8, dy: -8)
        let overlap = toolbarFrame.intersection(pageFrame)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else {
            return []
        }

        return [CGRect(
            x: (overlap.minX - pageOrigin.x) / scale,
            y: (overlap.minY - pageOrigin.y) / scale,
            width: overlap.width / scale,
            height: overlap.height / scale
        )]
    }

    /// Older notes may still contain the original annotation layer. Include
    /// those marks—especially its `write` labels—in placement keep-out zones
    /// so newer AI explanations never cover prior AI content.
    private var legacyAnnotationAvoidRects: [CGRect] {
        guard aiBounds.width > 0, aiBounds.height > 0 else { return [] }

        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: aiBounds.minX + CGFloat(x) * aiBounds.width,
                    y: aiBounds.minY + CGFloat(y) * aiBounds.height)
        }

        return aiAnnotations.compactMap { annotation in
            switch annotation.type {
            case .circle, .highlight:
                guard let x = annotation.x, let y = annotation.y,
                      let width = annotation.width, let height = annotation.height else {
                    return nil
                }
                let origin = point(x, y)
                return CGRect(x: origin.x, y: origin.y,
                              width: CGFloat(width) * aiBounds.width,
                              height: CGFloat(height) * aiBounds.height)
            case .arrow:
                guard let x1 = annotation.x1, let y1 = annotation.y1,
                      let x2 = annotation.x2, let y2 = annotation.y2 else {
                    return nil
                }
                let start = point(x1, y1)
                let end = point(x2, y2)
                return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x),
                              height: abs(end.y - start.y))
                    .insetBy(dx: -8, dy: -8)
            case .write:
                guard let x = annotation.x, let y = annotation.y,
                      let text = annotation.text else { return nil }
                let origin = point(x, y)
                let font = UIFont.systemFont(ofSize: 18, weight: .semibold)
                let size = (text as NSString).size(withAttributes: [.font: font])
                return CGRect(origin: origin,
                              size: CGSize(width: ceil(size.width),
                                           height: ceil(font.lineHeight)))
            }
        }
    }

    private var orderedEnabledNativeToolIDs: [String] {
        EditorToolDescriptor.all.compactMap { descriptor in
            guard EditorPickerItemID.nativePickerIDs.contains(descriptor.id),
                  toolConfiguration.isEnabled(descriptor.id) else { return nil }
            return descriptor.id
        }
    }

    private var orderedEnabledInkingToolIDs: [String] {
        orderedEnabledNativeToolIDs.filter { $0 != EditorPickerItemID.eraser }
    }

    private var activeEditorToolID: String? {
        switch toolMode {
        case .ink:
            return selectedNativeToolID
        case .selection:
            return EditorPickerItemID.lasso
        case .text:
            return EditorPickerItemID.text
        case .shape(let kind):
            return EditorPickerItemID.shape(kind)
        }
    }

    private var selectedToolWidth: CGFloat {
        if selectedNativeToolID == EditorPickerItemID.eraser {
            let range = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
            return min(range.upperBound,
                       max(range.lowerBound, CGFloat(eraserWidth)))
        }
        return CGFloat(inkWidths[selectedNativeToolID] ?? 4)
    }

    private var inkColorBinding: Binding<Color> {
        Binding(
            get: { inkColor },
            set: { selectInkColor($0) }
        )
    }

    private var inkWidthBinding: Binding<Double> {
        Binding(
            get: { inkWidths[lastInkingToolID] ?? 4 },
            set: { width in
                guard orderedEnabledInkingToolIDs.contains(lastInkingToolID) else {
                    return
                }
                inkWidths[lastInkingToolID] = width
                selectedNativeToolID = lastInkingToolID
                toolMode = .ink
            }
        )
    }

    private func selectNativeTool(_ identifier: String) {
        guard toolConfiguration.isEnabled(identifier),
              EditorPickerItemID.nativePickerIDs.contains(identifier) else { return }
        selectedNativeToolID = identifier
        if identifier != EditorPickerItemID.eraser {
            lastInkingToolID = identifier
        }
        toolMode = .ink
    }

    private func selectEditorTool(_ identifier: String) {
        guard toolConfiguration.isEnabled(identifier) else { return }
        switch identifier {
        case EditorPickerItemID.lasso:
            toolMode = .selection
        case EditorPickerItemID.text:
            toolMode = .text
        default:
            if let kind = EditorPickerItemID.shapeKind(for: identifier) {
                toolMode = .shape(kind)
            } else {
                selectNativeTool(identifier)
            }
        }
    }

    private func selectInkColor(_ color: Color) {
        guard let inkingID = resolvedEnabledInkingToolID() else { return }
        inkColor = color
        lastInkingToolID = inkingID
        selectedNativeToolID = inkingID
        toolMode = .ink
    }

    private func openInkSettings() {
        guard let inkingID = resolvedEnabledInkingToolID() else { return }
        lastInkingToolID = inkingID
        selectedNativeToolID = inkingID
        toolMode = .ink
        showInkSettings = true
    }

    private func openToolSettings() {
        if toolMode == .ink,
           selectedNativeToolID == EditorPickerItemID.eraser {
            showEraserSettings = true
        } else {
            openInkSettings()
        }
    }

    private func resolvedEnabledInkingToolID() -> String? {
        if orderedEnabledInkingToolIDs.contains(lastInkingToolID) {
            return lastInkingToolID
        }
        return orderedEnabledInkingToolIDs.first
    }

    private func normalizeNativeToolSelection() {
        let enabled = orderedEnabledNativeToolIDs
        guard !enabled.isEmpty else { return }
        if !enabled.contains(selectedNativeToolID) {
            selectedNativeToolID = enabled.first ?? EditorPickerItemID.pen
        }
        if selectedNativeToolID != EditorPickerItemID.eraser {
            lastInkingToolID = selectedNativeToolID
        } else if let fallback = orderedEnabledInkingToolIDs.first {
            lastInkingToolID = fallback
        }
    }

    private var separatedToolSymbol: String {
        switch toolMode {
        case .text:
            return "character.cursor.ibeam"
        case .shape(let kind):
            return kind.symbolName
        case .selection:
            return "lasso"
        case .ink:
            return "square.on.circle"
        }
    }

    private func pageDisplayScale(pageSize: CGSize,
                                  viewportSize: CGSize) -> CGFloat {
        guard pageSize.width > 0, pageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        return min(viewportSize.width / pageSize.width,
                   viewportSize.height / pageSize.height)
    }

    private func saveAnnotations() {
        let stored = StoredAnnotations(annotations: aiAnnotations, bounds: aiBounds)
        page.annotationData = (try? JSONEncoder().encode(stored)) ?? Data()
    }

    private func saveAIDrawing() {
        let stored = StoredAIDrawing(
            pkDrawingBytes: aiPlayer.committedDrawing.dataRepresentation(),
            labels: aiPlayer.labels,
            reservedRects: aiPlayer.reservedRects.map(StoredCanvasRect.init)
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

                // Imported PDF page or image, laid out exactly like the
                // SwiftUI aspect-fit background beneath the live canvas.
                // Its container is the page's original coordinate space,
                // not today's viewport, so ink stays attached after resize.
                if let backgroundImage {
                    let canvasRect = aspectFitRect(
                        contentSize: backgroundImage.size,
                        container: CGRect(origin: .zero, size: stablePageSize)
                    )
                    backgroundImage.draw(
                        in: CGRect(
                            x: canvasRect.minX * scale,
                            y: canvasRect.minY * scale,
                            width: canvasRect.width * scale,
                            height: canvasRect.height * scale
                        )
                    )
                }

                // User's strokes.
                drawing.image(from: bounds, scale: scale)
                    .draw(in: CGRect(origin: .zero, size: size))

                // Typed text is a first-class user layer and must be visible
                // to the tutor just like handwriting.
                drawUserText(in: size, scale: scale)

                // AI's strokes (so the model can see what it already drew).
                aiPlayer.committedDrawing.image(from: bounds, scale: scale)
                    .draw(in: CGRect(origin: .zero, size: size))

                // AI text labels.
                for label in aiPlayer.labels {
                    if label.format == "latex" {
                        let formula = MathLabelRenderer.image(
                            latex: label.text,
                            color: AIPalette.uiColor(label.color),
                            fontSize: CGFloat(label.fontSize ?? 22),
                            scale: 2
                        )
                        let formulaSize = CGSize(width: formula.size.width * scale,
                                                 height: formula.size.height * scale)
                        formula.draw(in: CGRect(
                            x: (label.canvasX - bounds.minX) * scale
                                - formulaSize.width / 2,
                            y: (label.canvasY - bounds.minY) * scale
                                - formulaSize.height / 2,
                            width: formulaSize.width,
                            height: formulaSize.height
                        ))
                        continue
                    }
                    let plain = AILabelLayout.plainImage(
                        text: label.text,
                        color: AIPalette.uiColor(label.color),
                        fontSize: CGFloat(label.fontSize ?? 16),
                        leading: label.alignment == "leading",
                        scale: 2
                    )
                    let plainSize = CGSize(width: plain.size.width * scale,
                                           height: plain.size.height * scale)
                    plain.draw(in: CGRect(
                        x: (label.canvasX - bounds.minX) * scale
                            - plainSize.width / 2,
                        y: (label.canvasY - bounds.minY) * scale
                            - plainSize.height / 2,
                        width: plainSize.width,
                        height: plainSize.height
                    ))
                }

                // The tutor prompt uses this hidden coordinate grid for
                // precise placement even when the student-facing overlay is
                // off, so every transmitted frame must retain it.
                drawGrid(in: ctx.cgContext, size: size)
            }
        }
        return image
    }

    private func aspectFitRect(contentSize: CGSize,
                               container: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              container.width > 0, container.height > 0 else { return container }
        let scale = min(container.width / contentSize.width,
                        container.height / contentSize.height)
        let fitted = CGSize(width: contentSize.width * scale,
                            height: contentSize.height * scale)
        return CGRect(
            x: container.midX - fitted.width / 2,
            y: container.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func drawUserText(in size: CGSize, scale: CGFloat) {
        for box in textStore.boxes {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: box.fontSize * scale),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ]
            let string = NSAttributedString(string: box.text, attributes: attributes)
            let width = max(1, (box.frame.width - 12) * scale)
            let rect = CGRect(
                x: (box.frame.x + 6) * scale,
                y: box.frame.y * scale,
                width: width,
                height: min(size.height - box.frame.y * scale,
                            box.frame.height * scale)
            )
            string.draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        }
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
