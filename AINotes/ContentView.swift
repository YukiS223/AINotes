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
            // SIDEBAR: notebook list
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
            // DETAIL: pages of the selected notebook
            if let notebook = selectedNotebook {
                NotebookView(notebook: notebook)
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
        // Start every new notebook with one blank page
        let firstPage = Page(index: 0)
        firstPage.notebook = nb
        nb.pages.append(firstPage)
        context.insert(nb)
        selectedNotebook = nb
    }

    private func deleteNotebooks(at offsets: IndexSet) {
        for index in offsets {
            context.delete(notebooks[index])
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
    
    var body: some View {
        CanvasView(drawing: $drawing)
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                if !page.drawingData.isEmpty,
                   let loaded = try? PKDrawing(data: page.drawingData) {
                    drawing = loaded
                }
            }
            .onChange(of: drawing) { _, newValue in
                page.drawingData = newValue.dataRepresentation()
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    showTutor = true
                } label: {
                    Label("Tutor", systemImage: "sparkles")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding()
            }
            .sheet(isPresented: $showTutor) {
                TutorPanel(captureSnapshot: snapshot)
            }
    }
    
    private func snapshot() -> UIImage? {
        let drawingBounds = drawing.bounds
        let bounds = drawingBounds.isEmpty
        ? CGRect(x: 0, y: 0, width: 1024, height: 1366)
        : drawingBounds.insetBy(dx: -40, dy: -40)
        
        // PKDrawing renders strokes on a transparent background.
        // JPEG can't represent transparency, so we composite onto white first.
        let strokeImage = drawing.image(from: bounds, scale: 2.0)
        let renderer = UIGraphicsImageRenderer(size: strokeImage.size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: strokeImage.size))
            strokeImage.draw(in: CGRect(origin: .zero, size: strokeImage.size))
        }
    }
}
