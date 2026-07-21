import SwiftUI
import PencilKit

/// A flat drawing toolbar avoids PencilKit's forced 3D edge blur while the
/// underlying PKCanvasView continues to provide native ink and selection.
struct EditorInkToolbar: View {
    let enabledIDs: Set<String>
    let activeToolID: String?
    let inkColor: Color
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onSelectTool: (String) -> Void
    let onSelectColor: (Color) -> Void
    let onShowToolSettings: () -> Void
    let onCustomize: () -> Void
    let onMoveChanged: (CGSize) -> Void
    let onMoveEnded: (CGSize) -> Void

    private let presetColors: [Color] = [.black, .blue, .green]

    private var tools: [EditorToolDescriptor] {
        EditorToolDescriptor.all.filter { enabledIDs.contains($0.id) }
    }

    private var hasInkingTool: Bool {
        tools.contains {
            $0.id == EditorPickerItemID.pen
                || $0.id == EditorPickerItemID.pencil
                || $0.id == EditorPickerItemID.marker
        }
    }

    private var hasStyleTool: Bool {
        hasInkingTool || tools.contains { $0.id == EditorPickerItemID.eraser }
    }

    private var isEraserActive: Bool {
        activeToolID == EditorPickerItemID.eraser
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            compactToolbar
                .fixedSize(horizontal: true, vertical: true)
            scrollingToolbar
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drawing tools")
    }

    private var compactToolbar: some View {
        toolbarChrome(
            HStack(spacing: 7) {
                fixedLeadingControls
                toolControls
                fixedTrailingControls
            }
        )
    }

    /// Move/undo/redo and settings stay reachable while the enabled drawing
    /// tools themselves scroll. This keeps lasso, text, and every shape in
    /// the unified bar even in Split View and compact layouts.
    private var scrollingToolbar: some View {
        toolbarChrome(
            HStack(spacing: 7) {
                fixedLeadingControls

                ScrollView(.horizontal, showsIndicators: true) {
                    toolControls
                        .padding(.horizontal, 3)
                }
                .frame(maxWidth: .infinity)

                fixedTrailingControls
            }
        )
        .frame(maxWidth: 760)
    }

    private var fixedLeadingControls: some View {
        HStack(spacing: 7) {
            moveHandle

            separator

            toolbarButton("Undo", symbol: "arrow.uturn.backward", action: onUndo)
            toolbarButton("Redo", symbol: "arrow.uturn.forward", action: onRedo)

            separator
        }
    }

    private var toolControls: some View {
        HStack(spacing: 7) {
            ForEach(tools) { tool in
                toolbarButton(
                    tool.title,
                    symbol: tool.symbol,
                    isSelected: activeToolID == tool.id
                ) {
                    onSelectTool(tool.id)
                }
            }

            if hasInkingTool {
                separator

                ForEach(Array(presetColors.enumerated()), id: \.offset) { _, color in
                    Button {
                        onSelectColor(color)
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 25, height: 25)
                            .overlay {
                                Circle()
                                    .stroke(.white.opacity(0.9), lineWidth: 2)
                                    .padding(2)
                                    .opacity(colorMatches(color) ? 1 : 0)
                            }
                            .overlay {
                                Circle().stroke(.primary.opacity(0.16), lineWidth: 1)
                            }
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(colorName(color))
                    .accessibilityAddTraits(colorMatches(color) ? .isSelected : [])
                }
            }
        }
    }

    private var fixedTrailingControls: some View {
        HStack(spacing: 7) {
            if hasStyleTool {
                separator
                toolbarButton(
                    isEraserActive ? "Eraser Size" : "Ink Settings",
                    symbol: isEraserActive ? "eraser" : "paintpalette",
                    action: onShowToolSettings
                )
            }
            toolbarButton("Customize Tools", symbol: "slider.horizontal.3",
                          action: onCustomize)
        }
    }

    private func toolbarChrome<Content: View>(_ content: Content) -> some View {
        content
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(.primary.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .padding(.vertical, 5)
    }

    private var moveHandle: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onMoveChanged($0.translation) }
                    .onEnded { onMoveEnded($0.translation) }
            )
            .accessibilityLabel("Move toolbar")
            .accessibilityHint("Drag to reposition the drawing toolbar")
    }

    private var separator: some View {
        Divider()
            .frame(height: 26)
            .padding(.horizontal, 1)
    }

    private func toolbarButton(
        _ title: String,
        symbol: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 38, height: 38)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(
                    isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func colorMatches(_ color: Color) -> Bool {
        UIColor(inkColor).isEqual(UIColor(color))
    }

    private func colorName(_ color: Color) -> String {
        if UIColor(color).isEqual(UIColor.black) { return "Black ink" }
        if UIColor(color).isEqual(UIColor.blue) { return "Blue ink" }
        return "Green ink"
    }
}

struct EditorInkSettingsView: View {
    @Binding var color: Color
    @Binding var width: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Color") {
                    ColorPicker("Ink Color", selection: $color,
                                supportsOpacity: true)
                }

                Section("Stroke Width") {
                    Slider(value: $width, in: 1...24, step: 0.5) {
                        Text("Width")
                    } minimumValueLabel: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                    } maximumValueLabel: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 16))
                    }
                    Text("\(width, specifier: "%.1f") pt")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ink Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct EditorEraserSettingsView: View {
    @Binding var width: Double
    @Environment(\.dismiss) private var dismiss

    private var widthRange: ClosedRange<Double> {
        let range = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    private var clampedWidth: Double {
        min(widthRange.upperBound, max(widthRange.lowerBound, width))
    }

    private var sliderWidth: Binding<Double> {
        Binding(
            get: { clampedWidth },
            set: { width = min(widthRange.upperBound,
                               max(widthRange.lowerBound, $0)) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Eraser Size") {
                    Slider(value: sliderWidth, in: widthRange) {
                        Text("Size")
                    } minimumValueLabel: {
                        Image(systemName: "circle")
                            .font(.system(size: 6))
                    } maximumValueLabel: {
                        Image(systemName: "circle")
                            .font(.system(size: 20))
                    }
                    Text("\(clampedWidth, specifier: "%.0f") pt")
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear {
                // Migrate the zero width saved by the old vector eraser.
                width = clampedWidth
            }
            .navigationTitle("Eraser Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
