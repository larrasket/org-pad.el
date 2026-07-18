import SwiftUI
import PencilKit
import UIKit

// MARK: - Backgrounds
//
// Two INDEPENDENT choices, decoupled on purpose:
//
//   * SurfaceStyle  — what the artist SEES behind the ink while drawing. Purely
//     visual, app-side, never touches the exported pixels. Lets you draw with a
//     white pen on a dark surface and still export transparent.
//
//   * CanvasBackground — what gets BAKED into the exported PNG (or transparent).
//     This is the "result" background; it can be suggested by the server
//     (`org-pad-figure-background`) and overridden in the toolbar.
//
// Default surface is `.neutral` (a checkerboard, so both light and dark ink
// read); default export is `.transparent` (theme-adaptive).

/// The visible drawing-surface style (does NOT affect the exported PNG).
enum SurfaceStyle: String, CaseIterable, Identifiable {
    case neutral   // checkerboard — both light and dark ink stay visible
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .neutral: return "Neutral"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var symbol: String {
        switch self {
        case .neutral: return "checkerboard.rectangle"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }
}

/// The background baked into the exported PNG (the "result").
enum CanvasBackground: String, CaseIterable, Identifiable {
    case transparent
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transparent: return "Transparent"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var symbol: String {
        switch self {
        case .transparent: return "square.dashed"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }

    /// The opaque fill color to bake behind the ink on export, or nil for a
    /// transparent PNG (no fill; alpha preserved).
    var bakedFillColor: UIColor? {
        switch self {
        case .transparent: return nil
        case .dark: return UIColor(white: 0.11, alpha: 1.0)   // ~#1C1C1E, Notes dark
        case .light: return UIColor.white
        }
    }
}

// MARK: - Export geometry (unchanged from v1)

enum ExportGeometry {
    /// Export bounds = union of stroke bounds inset by -20 pt, minimum 200x150,
    /// centered on the drawing's center. `drawingBounds` is PKDrawing.bounds.
    static func exportRect(drawingBounds: CGRect) -> CGRect {
        if drawingBounds.isNull || drawingBounds.isEmpty {
            return CGRect(x: 0, y: 0, width: 200, height: 150)
        }
        var rect = drawingBounds.insetBy(dx: -20, dy: -20)
        if rect.width < 200 || rect.height < 150 {
            let w = max(rect.width, 200), h = max(rect.height, 150)
            let cx = rect.midX, cy = rect.midY
            rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        }
        return rect
    }
}

// MARK: - PencilKit wrapper

struct PKCanvasRepresentable: UIViewRepresentable {
    @ObservedObject var model: CanvasModel
    let allowsFingerDrawing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        // The PKCanvasView itself stays clear/non-opaque; the visible surface
        // color is a SwiftUI layer beneath it (so transparent shows a neutral
        // check pattern and dark/light show a solid). Keeping the canvas clear
        // means the exported ink is never contaminated by a surface fill.
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        if let data = model.initialDrawingData, let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        }
        // Seed the add-detector with the pre-existing stroke count and attach the
        // delegate ONLY AFTER the saved drawing is installed, so re-opening an
        // edit figure is never mis-detected as a user stroke addition (which
        // would otherwise snap/smooth previously-saved ink the instant it opens).
        model.lastStrokeCount = canvas.drawing.strokes.count
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly
        let picker = context.coordinator.toolPicker
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        // Defer becomeFirstResponder() until the view is in the hierarchy.
        // Must be a main-actor Task, not DispatchQueue.main.async: the latter's
        // @Sendable closure is nonisolated, and calling the @MainActor method
        // becomeFirstResponder() from it is a hard isolation error under Swift
        // Playgrounds' Swift-5.9-mode toolchain.
        Task { @MainActor in canvas.becomeFirstResponder() }
        model.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.drawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly
        context.coordinator.model = model
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var model: CanvasModel
        let toolPicker = PKToolPicker()   // iPadOS 16: instantiate directly

        /// Guards against re-entrancy: replacing a stroke mutates `drawing`,
        /// which fires `canvasViewDrawingDidChange` again. Without this flag the
        /// smart-ink pass would recurse on its own substitution.
        private var isApplyingSmartInk = false

        init(model: CanvasModel) { self.model = model }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if isApplyingSmartInk { return }

            let snap = model.snapShapes
            let smooth = model.smoothInk

            // Only act on stroke ADDITIONS (a new stroke just finished). We
            // detect this by comparing the stroke count to the last seen count;
            // erases/undo reduce the count and must not trigger snapping.
            let strokes = canvasView.drawing.strokes
            // Only a genuine ink ADD counts. The vector eraser SPLITS a stroke
            // (raising the count), so gate on the active tool not being an
            // eraser — otherwise erasing a gap would snap/smooth the fragment.
            let didAddStroke = strokes.count > model.lastStrokeCount
                && !(toolPicker.selectedTool is PKEraserTool)
            model.lastStrokeCount = strokes.count
            model.hasStrokes = !strokes.isEmpty

            guard (snap || smooth), didAddStroke, let last = strokes.last else { return }

            let result = SmartInk.process(stroke: last, snap: snap, smooth: smooth)
            guard let replacement = result.replacement else { return }

            // Replace the just-finished stroke with the idealized/smoothed one.
            // PKDrawing is a value type; rebuild strokes with the last swapped.
            isApplyingSmartInk = true
            var newStrokes = strokes
            newStrokes[newStrokes.count - 1] = replacement
            canvasView.drawing = PKDrawing(strokes: newStrokes)
            model.lastStrokeCount = canvasView.drawing.strokes.count
            isApplyingSmartInk = false

            if let shape = result.recognized {
                model.lastRecognized = shape
            }
        }
    }
}

// MARK: - Canvas model (owns the live canvas + export/upload)

@MainActor
final class CanvasModel: ObservableObject {
    let session: Session
    let initialDrawingData: Data?
    @Published var hasStrokes = false
    @Published var isUploading = false
    @Published var uploadFailed = false

    /// Smart-ink toggles (persisted app-wide so the user's preference sticks).
    @AppStorage("orgpad.snapShapes") var snapShapes = false
    @AppStorage("orgpad.smoothInk") var smoothInk = false

    /// The background baked into the exported PNG (the "result"). Independent of
    /// the on-screen surface (which is a View-side @AppStorage preference).
    @Published var exportBackground: CanvasBackground

    /// Non-published bookkeeping used by the coordinator.
    var lastStrokeCount = 0
    var lastRecognized: RecognizedShape?

    weak var canvas: PKCanvasView?
    private weak var connection: ConnectionStore?
    private weak var loop: SessionLoop?

    init(session: Session, connection: ConnectionStore?, loop: SessionLoop?) {
        self.session = session
        self.connection = connection
        self.loop = loop
        self.initialDrawingData = session.drawingData
        self.hasStrokes = session.isEdit && session.drawingData != nil
        // Honor a server-suggested export background if present, else default to
        // the theme-adaptive transparent result.
        self.exportBackground = session.suggestedBackground ?? .transparent
    }

    func rebind(connection: ConnectionStore, loop: SessionLoop) {
        self.connection = connection; self.loop = loop
    }

    func undo() { canvas?.undoManager?.undo() }
    func redo() { canvas?.undoManager?.redo() }

    var canUndo: Bool { canvas?.undoManager?.canUndo ?? false }
    var canRedo: Bool { canvas?.undoManager?.canRedo ?? false }

    /// Render the ink to a PNG.
    ///
    /// TRANSPARENT BY DEFAULT: `format.opaque = false` and NO white fill, so the
    /// true ink colors + per-stroke alpha survive and dark-mode org renders the
    /// figure without a white slab. If `background` is `.dark`/`.light`, that
    /// solid color is baked behind the ink. Always returns the raw PKDrawing
    /// bytes (format 0x01) alongside.
    func exportPNG() -> (png: Data, drawing: Data)? {
        guard let canvas else { return nil }
        let drawing = canvas.drawing
        let rect = ExportGeometry.exportRect(drawingBounds: drawing.bounds)
        let scale: CGFloat = 2
        let inkImage = drawing.image(from: rect, scale: scale)   // transparent bg

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false   // <-- the fix: never force an opaque canvas

        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        let bake = exportBackground.bakedFillColor
        let composited = renderer.image { ctx in
            if let bake {
                bake.setFill()
                ctx.fill(CGRect(origin: .zero, size: rect.size))
            }
            // With opaque=false and no fill (transparent case), the ink draws
            // onto a fully transparent bitmap, preserving color + alpha exactly.
            inkImage.draw(in: CGRect(origin: .zero, size: rect.size))
        }
        guard let png = composited.pngData() else { return nil }
        return (png, drawing.dataRepresentation())
    }

    func done() async { await deliver() }
    func retry() async { await deliver() }

    private func deliver() async {
        guard let export = exportPNG(), let client = connection?.client else {
            uploadFailed = true; return
        }
        await upload(png: export.png, drawing: export.drawing, client: client)
    }

    private func upload(png: Data, drawing: Data, client: OrgPadClient) async {
        isUploading = true; uploadFailed = false
        defer { isUploading = false }
        do {
            // Wire JSON is unchanged: {session_id, png, drawing}. The chunk
            // FORMAT (0x01 = Apple PKDrawing) is implied by this being the
            // native client; the elisp side tags the orPd chunk 0x01.
            let req = try client.resultRequest(
                sessionID: session.sessionID,
                pngBase64: png.base64EncodedString(),
                drawingBase64: drawing.base64EncodedString())
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { uploadFailed = true; return }
            switch http.statusCode {
            case 200: loop?.finishSession()
            case 401: connection?.invalidateToken()
            default: uploadFailed = true   // keep strokes, show Retry banner
            }
        } catch { uploadFailed = true }
    }

    func cancel() async {
        guard let client = connection?.client else { loop?.finishSession(); return }
        if let req = try? client.cancelRequest(sessionID: session.sessionID) {
            _ = try? await URLSession.shared.data(for: req)
        }
        loop?.finishSession()
    }
}

// MARK: - Screen

struct CanvasScreen: View {
    let session: Session
    @EnvironmentObject var connection: ConnectionStore
    @EnvironmentObject var loop: SessionLoop
    @StateObject private var model: CanvasModel
    @AppStorage("orgpad.fingerDrawing") private var allowsFingerDrawing = false
    /// The visible drawing surface — independent of the exported background, and
    /// persisted app-wide. Default `.neutral` keeps both light and dark ink
    /// visible; pick `.dark` to draw with a white pen and still export transparent.
    @AppStorage("orgpad.surface") private var surface: SurfaceStyle = .neutral
    @State private var toolbarTick = 0   // pokes undo/redo enablement refresh

    init(session: Session) {
        self.session = session
        _model = StateObject(wrappedValue: CanvasModel(session: session, connection: nil, loop: nil))
    }

    var body: some View {
        ZStack(alignment: .top) {
            surfaceBackground
                .ignoresSafeArea()
            PKCanvasRepresentable(model: model, allowsFingerDrawing: allowsFingerDrawing)
                .ignoresSafeArea()
            if model.uploadFailed { retryBanner }
        }
        .overlay(alignment: .bottom) { toolbar }
        .onAppear { model.rebind(connection: connection, loop: loop) }
    }

    // The visible surface beneath the (clear) PKCanvasView. Driven ONLY by the
    // `surface` preference — it never affects the exported PNG.
    @ViewBuilder
    private var surfaceBackground: some View {
        switch surface {
        case .neutral:
            // A neutral checkerboard so BOTH light and dark ink stay visible.
            TransparentCheckerboard()
        case .dark:
            Color(UIColor(white: 0.11, alpha: 1.0))
        case .light:
            Color.white
        }
    }

    // MARK: Rich, Notes-like toolbar

    private var toolbar: some View {
        OrgPadGlassContainer(spacing: 12) {
            HStack(spacing: 14) {
                // Leading: cancel + background picker
                Button(role: .cancel) { Task { await model.cancel() } } label: {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(width: 34, height: 34)
                }
                .orgPadGlassButton()

                backgroundMenu

                Divider().frame(height: 24)

                // Center: undo / redo (prominent, Notes-like)
                Button { model.undo(); toolbarTick += 1 } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 34, height: 34)
                }
                .orgPadGlassButton()
                .disabled(!model.canUndo)

                Button { model.redo(); toolbarTick += 1 } label: {
                    Image(systemName: "arrow.uturn.forward").frame(width: 34, height: 34)
                }
                .orgPadGlassButton()
                .disabled(!model.canRedo)

                Divider().frame(height: 24)

                // Smart-ink toggles
                smartToggle(on: $model.snapShapes, symbol: "scribble.variable", title: "Snap")
                smartToggle(on: $model.smoothInk, symbol: "wand.and.stars", title: "Smooth")

                Divider().frame(height: 24)

                Toggle(isOn: $allowsFingerDrawing) {
                    Image(systemName: "hand.point.up.left")
                }
                .toggleStyle(.button)
                .orgPadGlassButton()

                Spacer(minLength: 8)

                // Trailing: primary action
                Button { Task { await model.done() } } label: {
                    if model.isUploading {
                        ProgressView().frame(width: 60, height: 34)
                    } else {
                        Label("Done", systemImage: "checkmark")
                            .frame(height: 34).padding(.horizontal, 8)
                    }
                }
                .orgPadGlassProminentButton()
                .disabled(model.isUploading)
                .tint(.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .orgPadGlassCapsule()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .id(toolbarTick)   // recompute disabled(undo/redo) after actions
    }

    private var backgroundMenu: some View {
        Menu {
            Picker("Surface (what you see)", selection: $surface) {
                ForEach(SurfaceStyle.allCases) { s in
                    Label(s.label, systemImage: s.symbol).tag(s)
                }
            }
            Picker("Export (the result)", selection: $model.exportBackground) {
                ForEach(CanvasBackground.allCases) { bg in
                    Label(bg.label, systemImage: bg.symbol).tag(bg)
                }
            }
        } label: {
            Image(systemName: "square.on.square.dashed")
                .frame(width: 34, height: 34)
        }
        .orgPadGlassButton()
    }

    private func smartToggle(on: Binding<Bool>, symbol: String, title: String) -> some View {
        Toggle(isOn: on) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .orgPadGlassButton()
        .accessibilityLabel(title)
    }

    private var retryBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Upload failed — your drawing is safe.")
            Spacer()
            Button("Discard") { loop.finishSession() }
                .orgPadGlassButton()
            Button("Retry") { Task { await model.retry() } }
                .orgPadGlassProminentButton()
                .tint(.orange)
        }
        .padding()
        .orgPadGlass(in: RoundedRectangle(cornerRadius: 18), tint: .orange)
        .padding()
    }
}

// MARK: - Transparent surface indicator

/// A subtle checkerboard drawn behind a transparent-export canvas so the artist
/// sees a neutral mid-tone (never invisible ink) and understands the export
/// will have no baked background.
private struct TransparentCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 16
            let light = Color(white: 0.55)
            let dark = Color(white: 0.42)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = (row % 2 == 0) ? 0 : tile
                while x < size.width {
                    let r = CGRect(x: x, y: y, width: tile, height: tile)
                    context.fill(Path(r), with: .color(dark))
                    x += tile * 2
                }
                y += tile
                row += 1
            }
        }
    }
}
