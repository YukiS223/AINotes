# AINotes

AINotes is an AI-assisted note-taking app for iPhone and iPad, built with SwiftUI, PencilKit, and SwiftData. It combines familiar handwriting and document-annotation tools with a live Gemini tutor that can see the current page, hear questions, respond by voice, and add equations, graphs, diagrams, and annotations directly to the canvas.

## Features

### Note taking

- Organize notes into persistent notebooks and pages.
- Draw with PencilKit pens, pencils, markers, and the vector eraser.
- Select handwriting with the lasso and use native copy, cut, paste, delete, undo, and redo actions.
- Add, edit, move, copy, and delete typed text boxes.
- Import PDFs and images from Files or Photos.
- Convert every imported PDF page into a self-contained note page.
- Customize which pens, editing tools, and shape tools appear in the editor.

### Shapes and diagrams

- Draw explicit lines, arrows, rectangles, ellipses, and triangles.
- Use Smart Shape to correct hand-drawn lines and closed shapes.
- Generate structured trees and node/edge diagrams through the AI drawing system.
- Preserve straight corners on generated rectangles and triangles instead of smoothing them into rounded outlines.

### AI tutor

- Hold a bidirectional voice conversation through the Gemini Live API.
- Share compressed snapshots of the active canvas with the tutor while a live session is running.
- Display a rolling transcription of the tutor's response.
- Let the tutor circle work, point to an answer, add explanations, or construct a diagram with real canvas content.
- Report failed or partially placed drawing actions back to the model instead of claiming that missing content was drawn.

### Math and data visualization

- Render TeX-style equations with grouped superscripts, subscripts, fractions, roots, and integrals.
- Plot functions, parametric curves, implicit relations, and filled inequalities.
- Draw line, scatter, bar, histogram, and disk plots.
- Preserve equal axis scale for geometry such as `x^2 + y^2 <= 4`.
- Keep AI content inside the page and place it around handwriting, typed text, imported content, and earlier AI annotations.

## Requirements

- macOS with Xcode 26.5 or later
- iOS or iPadOS 26.5 or later
- A Gemini API key with access to the Gemini Live API
- A microphone for live tutoring sessions
- An Apple Pencil is optional; finger and indirect input are supported

The project currently targets both iPhone and iPad and is configured for the `gemini-3.1-flash-live-preview` model.

## Getting started

### 1. Open the project

Clone the repository, then open `AINotes.xcodeproj` in Xcode.

```bash
git clone <repository-url>
cd AINotes
open AINotes.xcodeproj
```

### 2. Add a Gemini API key

Create a local secrets file from the included example:

```bash
cp AINotes/Secrets.example.plist AINotes/Secrets.plist
```

Open `AINotes/Secrets.plist` and add your key:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>geminiAPIKey</key>
    <string>YOUR_GEMINI_API_KEY</string>
</dict>
</plist>
```

`Secrets.plist` is ignored by Git and must never be committed. The project uses an Xcode synchronized folder, so a secrets file created inside `AINotes/` is included in the app bundle automatically.

### 3. Configure signing

In Xcode:

1. Select the **AINotes** target.
2. Open **Signing & Capabilities**.
3. Choose your development team.
4. Change the bundle identifier if `com.yukis.AINotes` is not available to your team.

### 4. Run the app

Choose an iPhone or iPad simulator, or a connected device, and press **Run**.

The first live tutoring session requests microphone permission. The API key is read when **Start Live Session** is tapped, so ordinary note editing can be used before starting the tutor.

## Using AINotes

- Tap **+** in the notebook list to create a notebook.
- Use **Import** to add a PDF or image as note-page backgrounds.
- Use the PencilKit bar for ink, erasing, and lasso selection.
- Open the **Text and Shapes** menu in the navigation bar for typed text and shape tools.
- Use the sliders button on the PencilKit bar to customize available tools. A navigation-bar fallback is shown on compact layouts.
- Open **Tutor**, then tap **Start Live Session** to begin sharing voice and canvas context with Gemini.
- Use **Clear AI** to remove generated annotations while preserving the student's note content.

## Architecture

| Area | Main files | Responsibility |
| --- | --- | --- |
| App and persistence | `AINotesApp.swift`, `Item.swift` | SwiftData container, notebooks, pages, drawings, text, backgrounds, and AI layers |
| Editor UI | `ContentView.swift`, `CanvasView.swift` | Page composition, PencilKit integration, tool state, snapshots, and persistence |
| Text and shapes | `NoteTextTools.swift`, `ShapeTools.swift`, `EditorToolCustomization.swift` | Editable text boxes, corrected geometry, explicit shapes, and toolbar customization |
| Document import | `DocumentImport.swift`, `BackgroundOccupancy.swift` | PDF/image conversion, persistent page backgrounds, and occupied-region detection |
| AI drawing | `DrawingActions.swift`, `Aidrawing.swift`, `Annotations.swift` | Drawing schema, collision-aware placement, animation, labels, and annotations |
| Math rendering | `MathExpression.swift`, `MathLabelRenderer.swift`, `MathPlotRenderer.swift` | Expression parsing, TeX-style labels, plots, axes, data marks, and inequalities |
| Live tutor | `LiveSession.swift`, `GeminiLiveClient.swift`, `LiveAudioEngine.swift`, `TutorPanel.swift` | Gemini Live WebSocket, audio, canvas frames, tool calls, and tutor UI |

Notes are stored locally with SwiftData. PencilKit drawings use `PKDrawing` serialization, while imported backgrounds use SwiftData external storage. Each page keeps a stable logical coordinate system so handwriting and imported documents stay aligned after rotation or Split View resizing.

## Building from the command line

The project has no third-party package dependencies. A simulator build can be run with:

```bash
xcodebuild \
  -project AINotes.xcodeproj \
  -scheme AINotes \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Privacy and API-key security

- Notebook data is stored locally on the device by SwiftData.
- During a live session, microphone audio and JPEG snapshots of the active canvas are sent directly to Google's Gemini Live API.
- Ending the session stops audio capture, frame delivery, the WebSocket connection, and in-progress AI playback.
- `Secrets.plist` is excluded by `.gitignore`.

The current API-key approach is intended for local development. Because the key is bundled inside the app, it can be extracted from a distributed build. Before shipping publicly, replace the bundled key with a backend-issued credential or another server-mediated authentication design, and review Google's current API terms and data-handling requirements.

## Current limitations

- The configured Gemini model and Live API endpoint are preview APIs and may require future schema updates.
- AI drawing is additive. Replacing an entire generated tree currently requires **Clear AI**; extending a tree can reuse existing node anchors.
- Cloud synchronization, collaboration, and note export are not currently implemented.

## License

No license file is currently included. Add a license before redistributing the project or accepting external contributions.
