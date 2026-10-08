# PDF Notes App — Codex Build Specification

> **Status:** Prototype / MVP specification  
> **Primary target:** Surface Pro 11 (Windows, pen-first)  
> **Cross-platform targets:** Windows, iOS/iPadOS, macOS, Android  
> **Framework:** Flutter + Dart  
> **Core principle:** Keep the source PDF immutable during editing. Render the PDF as a background and store handwriting/annotations separately. Only write annotations into a PDF when the user explicitly exports an annotated copy.

---

## 1. Product Goal

Build a lightweight, fast, pen-first PDF note-taking application that can replace the user's current OneNote-based PDF workflow.

The app should prioritize:

1. Fast opening and navigation of large PDFs.
2. Low-latency handwriting with a stylus.
3. Natural Surface Pen behavior.
4. Simple controls with substantially less UI complexity than Xournal++.
5. No required subscription for essential PDF annotation.
6. Cross-platform support without sacrificing the Windows/Surface experience.
7. Reliable autosave without rewriting the PDF on every pen stroke.

This is **not** intended to be a full Adobe Acrobat replacement. The first versions should focus on reading, handwriting, highlighting, navigating, and exporting PDFs well.

---

## 2. Key Architectural Decision

### Do not modify the PDF for every stroke

During normal editing:

- Treat the original PDF as immutable/read-only.
- Render PDF pages as the background layer.
- Draw handwriting and other annotations in a separate vector overlay.
- Persist those annotations in an app-owned document sidecar/database.
- Re-render only the visible PDF content and annotation overlay.
- Do not repeatedly serialize or rewrite the source PDF.

When the user selects **Export annotated PDF**:

1. Open the original PDF.
2. Convert stored annotation coordinates into PDF page coordinates.
3. Add standard PDF annotations where practical, especially Ink annotations.
4. Save a new PDF file.
5. Never overwrite the original unless the user explicitly requests it in a later feature.

This separation is essential for performance and reliability.

---

## 3. Technology Stack

### Application

- **Flutter**
- **Dart**

Flutter is the shared UI/application layer for:

- Windows
- macOS
- iOS/iPadOS
- Android

### Rendering

Use a replaceable PDF rendering abstraction.

```text
PdfEngine
├── openDocument()
├── pageCount
├── getPageSize()
├── renderPage()
├── renderTile()
├── getMetadata()
└── closeDocument()
```

The initial backend may use a Flutter PDFium-based library or a thin native PDFium integration.

Do **not** make the rest of the application directly dependent on a particular PDF package. All PDF operations must go through the `PdfEngine` interface so the renderer can be replaced later without rewriting the editor.

### Drawing

Use Flutter's GPU-accelerated canvas APIs:

- `CustomPainter`
- pointer/stylus events
- `Canvas`
- `Path`
- cached display data where appropriate

Do not rasterize handwriting permanently during editing. Store strokes as vector points.

### Persistence

For the MVP, use a small local document database or compact serialized sidecar format.

Preferred logical structure:

```text
Original PDF
    +
App document metadata
    +
Per-page annotation data
```

The implementation should hide the storage backend behind repositories so SQLite, Isar, or another local database can be swapped later.

---

## 4. MVP Scope

The first usable prototype must support the following workflow:

```text
Open PDF
   ↓
Read / scroll / zoom
   ↓
Write on PDF with stylus
   ↓
Erase / undo / redo
   ↓
Close application
   ↓
Reopen document
   ↓
All annotations reappear in exactly the same positions
   ↓
Export annotated PDF
```

### Required MVP features

- Open a local PDF.
- Display PDFs in a vertically scrolling continuous document view.
- Render only pages near the viewport.
- Smooth scrolling.
- Pinch-to-zoom / touchpad zoom.
- Surface Pen / stylus handwriting.
- Pen pressure support when available.
- Pen draws while touch primarily navigates.
- Stroke color selection.
- Stroke width selection.
- Eraser.
- Undo.
- Redo.
- Autosave.
- Reopen recent documents.
- Restore saved annotations.
- Page thumbnail/navigation panel.
- Current page indicator.
- Basic fit-width / zoom controls.
- Export a new annotated PDF.
- Large-document performance suitable for PDFs with 300+ pages.

---

## 5. Explicitly Out of Scope for the Initial MVP

Do not spend early development time on:

- User accounts.
- Custom cloud backend.
- Collaboration.
- Real-time synchronization.
- OCR.
- AI features.
- PDF text editing.
- Complex form editing.
- Digital signatures.
- Advanced Acrobat-style document manipulation.
- Full OneNote-style notebook hierarchy.
- Audio recording.
- Infinite canvas.
- Rich typed-note blocks.
- Plugin system.

Blank note pages and richer notebook functionality can be added after the PDF annotation workflow is stable.

---

## 6. Input Model

The interaction model must distinguish between pen and touch.

### Pen

Default behavior:

- Pen tip → draw.
- Pressure → affect stroke width when pressure is available.
- Stylus eraser end → erase, when reported by the platform.
- Barrel button → may temporarily activate eraser or selection once platform behavior is stable.

### Touch

Default behavior:

- One-finger drag → scroll.
- Two-finger pinch → zoom.
- Touch must not accidentally create ink while the user is writing with a pen.

### Mouse / trackpad

- Wheel → scroll.
- Ctrl + wheel or platform-native gesture → zoom.
- Left drag behavior depends on active tool.
- Cursor should change appropriately for pen/eraser/selection tools.

### Palm rejection

Rely on platform pointer classification wherever possible.

When active stylus input is detected:

- Ignore touch contacts likely to be palm input.
- Do not convert generic touch input into pen strokes.

---

## 7. Ink Representation

A stroke should be stored as vector data.

Suggested model:

```dart
class InkStroke {
  String id;
  int pageIndex;
  List<InkPoint> points;
  double baseWidth;
  int argbColor;
  double opacity;
  StrokeTool tool;
  DateTime createdAt;
}

class InkPoint {
  double x;
  double y;
  double pressure;
  double timestamp;
}
```

### Coordinate system

Store annotation coordinates in **normalized page coordinates**, not screen pixels.

For example:

```text
normalizedX = pageLocalX / pageWidth
normalizedY = pageLocalY / pageHeight
```

Values should normally remain in:

```text
x: 0.0 → 1.0
y: 0.0 → 1.0
```

Benefits:

- annotations survive zoom changes;
- annotations survive window resizing;
- annotations remain stable across devices;
- mapping to PDF coordinates during export is straightforward.

Do not store only viewport coordinates.

---

## 8. Stroke Rendering

During active drawing:

1. Collect pointer samples.
2. Convert screen coordinates to page-local coordinates.
3. Convert page-local coordinates to normalized coordinates.
4. Append points to the current in-memory stroke.
5. Render the active stroke immediately.
6. Commit the completed stroke to document state.
7. Schedule persistence asynchronously after the stroke completes.

The user should never have to wait for disk writes before seeing ink.

### Smoothing

Start with a simple implementation:

- interpolate between sampled points;
- use quadratic/cubic curves;
- smooth sudden direction changes without noticeably altering handwriting.

Keep stroke smoothing isolated behind a component such as:

```text
StrokeSmoother
```

so the algorithm can later be replaced.

---

## 9. Eraser Behavior

MVP should support a **stroke eraser** first.

When the eraser intersects a stroke:

- remove the entire stroke.

This is simpler and faster than vector stroke splitting.

A later version may add:

- partial/path eraser;
- lasso selection;
- stroke splitting.

Eraser operations must be undoable.

---

## 10. Undo / Redo

Use a command-based history system.

Example operations:

```text
AddStroke
RemoveStroke
RemoveStrokeGroup
```

Requirements:

- Undo and redo should operate without modifying the PDF.
- History is scoped to the current document.
- A reasonable in-memory history limit should be used.
- The saved document state does not need to preserve the full undo stack between application launches in the MVP.

---

## 11. Rendering Architecture

Use independent layers.

```text
┌──────────────────────────────┐
│ Input / gesture layer        │
├──────────────────────────────┤
│ Annotation overlay           │
│ - ink                        │
│ - eraser feedback            │
│ - future highlights/selection│
├──────────────────────────────┤
│ Rendered PDF page            │
├──────────────────────────────┤
│ Page background/shadow       │
└──────────────────────────────┘
```

A PDF page repaint should **not** be required every time ink changes.

Likewise, scrolling or zooming should not cause all pages in the document to render at full resolution.

---

## 12. Large-PDF Performance Strategy

The application must be designed around lazy rendering from the beginning.

### Never render every page at startup

For a large document:

```text
far pages       → not rendered
nearby pages    → low/normal resolution cache
visible pages   → appropriate current-resolution render
active page     → highest priority
```

### Page virtualization

Only instantiate/render:

- visible pages;
- a small prefetch window before the viewport;
- a small prefetch window after the viewport.

Suggested starting window:

```text
visible pages ± 2 pages
```

Make this configurable.

### Render scheduling

Render priority:

1. page currently being written on;
2. visible pages;
3. immediately adjacent pages;
4. thumbnails;
5. farther prefetch work.

Rendering must happen off the UI thread whenever the PDF backend permits it.

### Cache

Maintain an LRU render cache.

Cache entries should be keyed by data such as:

```text
documentId
pageIndex
renderScale bucket
tile coordinates if tiled
```

The application must have a configurable memory budget and evict old renders.

---

## 13. Tiled Rendering

The architecture should allow tiled page rendering, even if the first prototype initially renders whole visible pages.

At high zoom levels, rendering an entire page at very high resolution wastes memory.

Preferred long-term design:

```text
PDF page
┌────┬────┬────┐
│ T1 │ T2 │ T3 │
├────┼────┼────┤
│ T4 │ T5 │ T6 │
├────┼────┼────┤
│ T7 │ T8 │ T9 │
└────┴────┴────┘
```

Only tiles intersecting the viewport need high-resolution rendering.

Keep the rendering API tile-capable from the beginning.

---

## 14. Performance Targets

These are engineering targets, not hard device guarantees.

### Surface Pro 11 target

- Normal scrolling should remain near 60 FPS or better.
- Ink should appear immediately under the pen with minimal perceived latency.
- Aim to take advantage of higher-refresh-rate displays when Flutter/platform support allows it.
- A 300+ page PDF must not require all pages to be decoded into memory.
- Opening a large PDF should show the first usable page before background work completes.
- Autosave must not visibly interrupt handwriting.
- Memory usage should remain bounded through page/tile eviction.

### Critical rule

Pen input and ink rendering have priority over background page rendering.

If the system is busy:

```text
pen rendering > visible PDF render > nearby preload > thumbnails
```

---

## 15. Document Model

Suggested top-level model:

```dart
class AppDocument {
  String id;
  String sourcePath;
  String displayName;
  String sourceFingerprint;
  int pageCount;
  DateTime openedAt;
  DateTime modifiedAt;
  Map<int, PageAnnotations> annotations;
}
```

```dart
class PageAnnotations {
  int pageIndex;
  List<InkStroke> strokes;
}
```

### PDF identity

Do not rely only on the absolute file path.

Store a fingerprint derived from stable information such as:

- file size;
- modified timestamp;
- optional partial/full content hash.

This helps detect when the source PDF has changed.

---

## 16. Persistence and Autosave

Autosave should save the **annotation model**, not rewrite the PDF.

Save triggers:

- shortly after a completed stroke;
- after erase operations;
- after undo/redo that changes current state;
- when the app loses focus;
- when the document closes;
- when the application shuts down normally.

Use debouncing so many strokes do not cause excessive writes.

Example behavior:

```text
Stroke complete
    ↓
Update in-memory state immediately
    ↓
Mark document dirty
    ↓
Debounced persistence
```

Use atomic writes/transactions so crashes do not corrupt the annotation document.

---

## 17. Export

Add a command:

```text
Export Annotated PDF…
```

Behavior:

1. Ask for an output location.
2. Read the original PDF.
3. Translate app annotations from normalized page coordinates into PDF coordinates.
4. Insert standard PDF Ink annotations where supported.
5. Preserve the original source PDF.
6. Save as a new file.
7. Show success/failure clearly.

The export implementation must live behind an interface:

```text
PdfExporter
```

This keeps annotation editing independent from the PDF-writing library.

---

## 18. User Interface

The UI should be intentionally minimal.

### Desktop/tablet layout

```text
┌─────────────────────────────────────────────────────────┐
│ Open  Pen  Eraser  Undo  Redo  Color  Width      Export│
├──────────┬──────────────────────────────────────────────┤
│          │                                              │
│ Pages    │                 PDF page                     │
│ /Thumbs  │                                              │
│          │                                              │
│          │                                              │
├──────────┴──────────────────────────────────────────────┤
│ Page 12 / 327                    Zoom 125%              │
└─────────────────────────────────────────────────────────┘
```

### Design goals

- maximize document space;
- large touch-friendly controls;
- hide secondary controls when not needed;
- pen settings should require very few taps;
- avoid dense Acrobat-style tool ribbons;
- avoid Xournal++-style configuration overload.

### MVP toolbar

Required:

- Open
- Pen
- Eraser
- Undo
- Redo
- Pen color
- Pen width
- Zoom/Fit
- Thumbnail toggle
- Export

---

## 19. Suggested Flutter Project Structure

```text
lib/
├── app/
│   ├── app.dart
│   ├── routes.dart
│   └── theme.dart
│
├── core/
│   ├── geometry/
│   ├── input/
│   ├── persistence/
│   └── utils/
│
├── features/
│   ├── document/
│   │   ├── data/
│   │   ├── domain/
│   │   └── presentation/
│   │
│   ├── pdf_viewer/
│   │   ├── domain/
│   │   │   └── pdf_engine.dart
│   │   ├── infrastructure/
│   │   └── presentation/
│   │
│   ├── annotations/
│   │   ├── data/
│   │   ├── domain/
│   │   │   ├── ink_point.dart
│   │   │   ├── ink_stroke.dart
│   │   │   └── annotation_repository.dart
│   │   ├── application/
│   │   │   ├── stroke_controller.dart
│   │   │   └── history_controller.dart
│   │   └── presentation/
│   │       └── ink_canvas.dart
│   │
│   ├── export/
│   │   ├── domain/
│   │   │   └── pdf_exporter.dart
│   │   └── infrastructure/
│   │
│   └── library/
│       ├── data/
│       └── presentation/
│
└── main.dart
```

Do not enforce this exact folder structure if a simpler equivalent remains clean. The important requirement is separation between:

- PDF rendering;
- annotation editing;
- persistence;
- export;
- UI.

---

## 20. Core Interfaces

Codex should define stable interfaces before tightly coupling the implementation to third-party packages.

### PDF engine

```dart
abstract interface class PdfEngine {
  Future<PdfDocumentHandle> open(String path);
}
```

```dart
abstract interface class PdfDocumentHandle {
  int get pageCount;

  Future<Size> getPageSize(int pageIndex);

  Future<PdfRenderedImage> renderPage({
    required int pageIndex,
    required double scale,
  });

  Future<PdfRenderedImage> renderTile({
    required int pageIndex,
    required Rect normalizedRegion,
    required double scale,
  });

  Future<void> close();
}
```

### Annotation repository

```dart
abstract interface class AnnotationRepository {
  Future<AppDocument?> loadForPdf(String path);
  Future<void> save(AppDocument document);
}
```

### Exporter

```dart
abstract interface class PdfExporter {
  Future<void> exportAnnotatedPdf({
    required AppDocument document,
    required String outputPath,
  });
}
```

---

## 21. State Management

Keep state management lightweight.

Required state categories:

- open document state;
- current viewport/page;
- zoom;
- active tool;
- pen settings;
- page annotations;
- undo/redo history;
- render/cache state;
- save state.

Do not place high-frequency raw pointer events into a global reactive store if doing so causes unnecessary widget rebuilds.

Active ink should be handled close to the canvas/rendering layer.

---

## 22. Threading / Isolate Rules

The UI thread should handle:

- pointer event intake;
- active ink rendering;
- lightweight state changes;
- compositing.

Move expensive work away from the UI thread where possible:

- PDF rasterization;
- export;
- hashing;
- large serialization;
- thumbnail generation.

Do not block pen rendering while waiting for any of these.

---

## 23. Error Handling

The app should gracefully handle:

- corrupt PDFs;
- password-protected PDFs;
- missing source PDFs;
- source PDF modified outside the application;
- failed autosave;
- failed export;
- insufficient storage;
- unsupported PDF features.

User-facing errors should be concise and recoverable.

Never silently discard unsaved annotations.

---

## 24. Recent Documents

Maintain a lightweight list of recently opened PDFs.

Each entry should contain:

- display name;
- path/URI;
- last opened time;
- optional thumbnail;
- annotation presence;
- missing-file status.

The app's launch screen can initially be:

```text
Recent documents
+
Open PDF
```

No notebook database is required for the MVP.

---

## 25. File and Cloud Strategy

### MVP

Support files available through the operating system file picker.

Start with:

- local files;
- files exposed to the OS by providers such as OneDrive where normal file APIs permit access.

Do not build a custom cloud sync service.

### Later

A sync abstraction can be added after local reliability is proven.

The application document/annotation format should therefore avoid embedding device-specific assumptions.

---

## 26. Future Features — After MVP

Possible post-MVP additions, in approximate priority order:

1. Highlighter.
2. Lasso selection.
3. Move/resize selected handwriting.
4. Partial-stroke eraser.
5. Insert blank note page between PDF pages.
6. Add pages after the document.
7. Text boxes.
8. Bookmarks.
9. Search PDF text.
10. Multiple document tabs.
11. Better OneDrive/iCloud/Google Drive integration.
12. Annotation import from existing PDF annotations.
13. Configurable pen presets.
14. Shape recognition.
15. Optional notebook/folder organization.

These features must not complicate the initial editor architecture unnecessarily.

---

## 27. Prototype Milestones

### Milestone 0 — Project skeleton

Deliver:

- Flutter project;
- Windows desktop target working;
- cross-platform targets retained;
- basic application shell;
- file picker;
- logging;
- unit-test setup.

Acceptance:

- app launches on Windows;
- user can choose a PDF.

---

### Milestone 1 — PDF viewer

Deliver:

- PDF open;
- page count;
- vertical continuous scroll;
- page virtualization;
- visible-page rendering;
- basic render cache;
- zoom;
- fit-width.

Acceptance:

- a 300+ page PDF opens without rendering all pages at once;
- user can scroll through it smoothly;
- memory usage does not grow indefinitely while scrolling.

---

### Milestone 2 — Ink prototype

Deliver:

- pen/touch distinction;
- stroke collection;
- normalized coordinates;
- annotation layer;
- pen width/color;
- pressure where available.

Acceptance:

- Surface Pen writes directly over the correct PDF page;
- touch can scroll without drawing;
- ink stays aligned while zooming and scrolling.

---

### Milestone 3 — Editing

Deliver:

- stroke eraser;
- undo;
- redo;
- current tool UI;
- shortcut support where practical.

Acceptance:

- edits happen only to annotation state;
- PDF background is never rewritten.

---

### Milestone 4 — Persistence

Deliver:

- stable document ID;
- annotation repository;
- autosave;
- reopen/recovery;
- recent documents.

Acceptance:

- annotate PDF;
- close app;
- reopen app;
- all marks return at the same coordinates.

---

### Milestone 5 — Navigation polish

Deliver:

- thumbnails;
- page number;
- jump to page;
- better zoom behavior;
- basic loading/error states.

---

### Milestone 6 — Export

Deliver:

- export dialog;
- annotation coordinate conversion;
- new annotated PDF output.

Acceptance:

- exported PDF opens in an external PDF reader;
- annotations appear on the correct pages and positions;
- original PDF remains unchanged.

---

### Milestone 7 — Surface Pro optimization

Profile and improve:

- pen latency;
- unnecessary Flutter rebuilds;
- render scheduling;
- page cache;
- memory use;
- thumbnail scheduling;
- gesture conflicts.

Do not optimize blindly; use profiling tools.

---

## 28. Minimum Automated Tests

### Geometry

Test:

- viewport → page-local coordinate conversion;
- page-local → normalized coordinate conversion;
- normalized → page-local conversion;
- normalized → PDF coordinate conversion.

### Annotation

Test:

- add stroke;
- erase stroke;
- undo add;
- undo erase;
- redo;
- serialization/deserialization.

### Document

Test:

- annotation data restored for correct PDF;
- source fingerprint mismatch detected.

### Cache

Test:

- LRU eviction;
- cache key differs by page/scale/tile.

### Export

At minimum, test coordinate conversion independently from the concrete PDF library.

---

## 29. Manual Test Checklist

Use a Surface Pro 11 for Windows-specific validation.

Test:

- [ ] Open a small PDF.
- [ ] Open a 300+ page PDF.
- [ ] Quickly scroll through many pages.
- [ ] Zoom repeatedly.
- [ ] Write slowly.
- [ ] Write rapidly.
- [ ] Write while resting palm on screen.
- [ ] Scroll using finger while pen is nearby.
- [ ] Change pen width.
- [ ] Change pen color.
- [ ] Erase strokes.
- [ ] Undo/redo repeatedly.
- [ ] Close immediately after drawing.
- [ ] Reopen and verify autosave.
- [ ] Resize the window and verify ink alignment.
- [ ] Rotate/orientation-change on mobile/tablet and verify ink alignment.
- [ ] Export and open result in another PDF reader.
- [ ] Verify original PDF was not modified.

---

## 30. Non-Negotiable Engineering Rules

1. **Never rewrite the PDF for every stroke.**
2. **Never render every page of a large PDF at startup.**
3. **Never store ink only in screen coordinates.**
4. **Do not block the UI thread on autosave or export.**
5. **Pen feedback takes priority over background rendering.**
6. **Keep the PDF rendering backend replaceable.**
7. **Keep the annotation store separate from the PDF file during editing.**
8. **The original PDF remains unchanged during normal use.**
9. **The MVP UI must remain simple and pen-first.**
10. **Windows/Surface behavior is the primary optimization target, but core architecture must remain portable.**

---

## 31. Definition of MVP Complete

The MVP is complete when the following scenario works reliably:

> On a Surface Pro 11, the user opens a large lecture PDF, scrolls to any page, writes notes naturally with the Surface Pen, navigates with touch, erases and undoes strokes, closes the application, reopens it later with all annotations preserved, and exports a new annotated PDF — without the original PDF being continuously rewritten and without the application becoming sluggish simply because the PDF has hundreds of pages.

---

## 32. Codex Starting Instructions

Codex should begin with the smallest vertical slice that proves the architecture.

### First implementation sequence

1. Create the Flutter project.
2. Enable Windows, macOS, iOS, and Android targets.
3. Implement `PdfEngine` abstraction.
4. Integrate one working PDF rendering backend.
5. Build one vertically scrolling virtualized PDF view.
6. Add an annotation `CustomPainter` over each visible page.
7. Implement stylus point collection and normalized coordinates.
8. Add basic pen drawing.
9. Add serialization and reload.
10. Only after this vertical slice works, add erasing, history, thumbnails, export, and polish.

### Initial success test

The first meaningful prototype should be able to:

```text
open PDF
→ render page
→ draw one pen stroke
→ save stroke separately
→ close document
→ reopen document
→ show the same stroke in the same location
```

Do not begin with cloud sync, notebook organization, or advanced PDF editing.

---

## 33. Guidance for Codex When Requirements Are Ambiguous

When choosing between implementations, prefer the one that:

1. reduces pen latency;
2. reduces PDF reprocessing;
3. keeps memory bounded;
4. preserves vector annotation data;
5. minimizes third-party lock-in;
6. keeps the interface simple;
7. works well on Windows/Surface;
8. remains portable to Apple and Android platforms.

If a feature conflicts with these priorities, defer the feature rather than weakening the core architecture.
