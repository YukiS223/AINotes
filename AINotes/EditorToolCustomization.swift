import SwiftUI
import PencilKit
import Observation

/// Stable identifiers are persisted instead of array positions so adding a
/// future tool does not scramble an existing user's customized picker.
enum EditorPickerItemID {
    static let pen = "com.yukis.ainotes.tool.pen"
    static let pencil = "com.yukis.ainotes.tool.pencil"
    static let marker = "com.yukis.ainotes.tool.marker"
    static let eraser = "com.yukis.ainotes.tool.eraser"
    static let lasso = "com.yukis.ainotes.tool.lasso"
    static let text = "com.yukis.ainotes.tool.text"

    /// Items rendered by PencilKit itself. Text and shapes live in the
    /// adjacent app toolbar menu because custom PencilKit item artwork is
    /// clipped in narrow iPad Split View and compact layouts.
    static let nativePickerIDs: Set<String> = [
        pen, pencil, marker, eraser, lasso
    ]

    static func shape(_ kind: ShapeKind) -> String {
        "com.yukis.ainotes.tool.shape.\(kind.rawValue)"
    }

    static func shapeKind(for identifier: String) -> ShapeKind? {
        let prefix = "com.yukis.ainotes.tool.shape."
        guard identifier.hasPrefix(prefix) else { return nil }
        return ShapeKind(rawValue: String(identifier.dropFirst(prefix.count)))
    }
}

struct EditorToolDescriptor: Identifiable, Hashable {
    enum Group: String, CaseIterable {
        case ink = "Pens"
        case editing = "Editing"
        case shapes = "Shapes"
    }

    let id: String
    let title: String
    let symbol: String
    let group: Group

    static let all: [EditorToolDescriptor] = [
        .init(id: EditorPickerItemID.pen, title: "Pen", symbol: "pencil.tip", group: .ink),
        .init(id: EditorPickerItemID.pencil, title: "Pencil", symbol: "pencil", group: .ink),
        .init(id: EditorPickerItemID.marker, title: "Marker", symbol: "highlighter", group: .ink),
        .init(id: EditorPickerItemID.eraser, title: "Eraser", symbol: "eraser", group: .editing),
        .init(id: EditorPickerItemID.lasso, title: "Lasso", symbol: "lasso", group: .editing),
        .init(id: EditorPickerItemID.text, title: "Text", symbol: "character.cursor.ibeam", group: .editing)
    ] + ShapeKind.allCases.map {
        .init(id: EditorPickerItemID.shape($0), title: $0.title,
              symbol: $0.symbolName, group: .shapes)
    }

    static let defaultIDs = Set(all.map(\.id))
}

@MainActor
@Observable
final class EditorToolConfiguration {
    static let shared = EditorToolConfiguration()

    private static let defaultsKey = "editor.enabledToolPickerItems.v1"
    private(set) var enabledIDs: Set<String>

    private init() {
        if let saved = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [String] {
            var known = Set(saved).intersection(EditorToolDescriptor.defaultIDs)
            if known.isEmpty { known = EditorToolDescriptor.defaultIDs }
            // The native picker must retain one real item even when the
            // separated Text/Shapes menu is the user's primary workflow.
            if known.isDisjoint(with: EditorPickerItemID.nativePickerIDs) {
                known.insert(EditorPickerItemID.pen)
            }
            enabledIDs = known
        } else {
            enabledIDs = EditorToolDescriptor.defaultIDs
        }
    }

    func isEnabled(_ identifier: String) -> Bool {
        enabledIDs.contains(identifier)
    }

    func setEnabled(_ enabled: Bool, for identifier: String) {
        guard EditorToolDescriptor.defaultIDs.contains(identifier) else { return }
        var next = enabledIDs
        if enabled {
            next.insert(identifier)
        } else {
            // PKToolPicker requires at least one item. Keeping the final
            // item also prevents a customized notebook from opening with
            // no way to select a tool.
            guard next.count > 1 else { return }
            next.remove(identifier)
            guard !next.isDisjoint(with: EditorPickerItemID.nativePickerIDs) else {
                return
            }
        }
        apply(next)
    }

    func reset() {
        apply(EditorToolDescriptor.defaultIDs)
    }

    private func apply(_ next: Set<String>) {
        guard next != enabledIDs, !next.isEmpty else { return }
        enabledIDs = next
        UserDefaults.standard.set(Array(next).sorted(), forKey: Self.defaultsKey)
    }
}

enum EditorToolPickerFactory {
    @MainActor
    static func make(enabledIDs: Set<String>) -> PKToolPicker {
        var items: [PKToolPickerItem] = []

        func include(_ identifier: String, _ item: @autoclosure () -> PKToolPickerItem) {
            if enabledIDs.contains(identifier) { items.append(item()) }
        }

        include(EditorPickerItemID.pen,
                PKToolPickerInkingItem(type: .pen, color: .label, width: 4,
                                        identifier: EditorPickerItemID.pen))
        include(EditorPickerItemID.pencil,
                PKToolPickerInkingItem(type: .pencil, color: .label, width: 4,
                                        identifier: EditorPickerItemID.pencil))
        include(EditorPickerItemID.marker,
                PKToolPickerInkingItem(type: .marker, color: .systemYellow, width: 12,
                                        identifier: EditorPickerItemID.marker))
        include(EditorPickerItemID.eraser,
                PKToolPickerEraserItem(type: .vector))
        include(EditorPickerItemID.lasso, PKToolPickerLassoItem())
        if items.isEmpty {
            items = [PKToolPickerInkingItem(type: .pen, color: .label, width: 4,
                                            identifier: EditorPickerItemID.pen)]
        }

        let picker = PKToolPicker(toolItems: items)
        picker.stateAutosaveName = "AINotes.UnifiedEditorTools"
        picker.showsDrawingPolicyControls = false
        return picker
    }
}

struct EditorToolCustomizationView: View {
    @Bindable var configuration: EditorToolConfiguration
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(EditorToolDescriptor.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(EditorToolDescriptor.all.filter { $0.group == group }) { tool in
                            Toggle(isOn: Binding(
                                get: { configuration.isEnabled(tool.id) },
                                set: { configuration.setEnabled($0, for: tool.id) }
                            )) {
                                Label(tool.title, systemImage: tool.symbol)
                            }
                        }
                    }
                }

                Section {
                    Button("Restore All Tools", action: configuration.reset)
                } footer: {
                    Text("Changes update the drawing toolbar immediately and apply to every note. The Customize Tools button always remains available.")
                }
            }
            .navigationTitle("Customize Tools")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
