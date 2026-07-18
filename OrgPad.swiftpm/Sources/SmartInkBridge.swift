import Foundation
import PencilKit
import CoreGraphics

// MARK: - Smart-ink bridge (PencilKit <-> SmartInk geometry engine)
//
// The seam between the UI (CanvasScreen) and the pure-math engine in
// SmartInk.swift. SmartInk.swift is UIKit/PencilKit-free ([CGPoint] in/out);
// this file adapts a live PKStroke to those functions and rebuilds a PKStroke
// from the result. The UI calls exactly one entry point: SmartInk.process(...).
//
// The pure geometry (classify/idealize/smooth) is verified off-device (32
// assertions, zero handwriting false-positives). The PencilKit glue below is
// authored against the iPadOS API and can only be exercised on a real device;
// on-device checklist items: delegate fire timing, PKStrokePath point access,
// undo granularity after a stroke swap, and ellipse render fidelity.

/// Shapes the recognizer can snap a rough stroke to (kind only; the geometry
/// lives in SmartInk's `SmartShape`). Surfaced to the UI for an optional HUD.
enum RecognizedShape: Equatable {
    case line, rectangle, ellipse, triangle, arrow
}

/// Result of processing a just-finished stroke.
struct SmartInkResult {
    /// The stroke to substitute for the raw one, or nil to keep the raw stroke.
    var replacement: PKStroke?
    /// What (if anything) was recognized.
    var recognized: RecognizedShape?
}

enum SmartInk {

    /// Decide whether to replace the stroke the user just finished.
    /// Precedence: if `snap` and a shape is recognized, the idealized shape wins;
    /// else if `smooth`, return the de-jittered stroke; else keep the raw ink.
    static func process(stroke: PKStroke, snap: Bool, smooth doSmooth: Bool) -> SmartInkResult {
        let raw = points(from: stroke)
        guard raw.count >= 2 else { return SmartInkResult(replacement: nil, recognized: nil) }

        if snap {
            let shape = classifyShape(raw)            // free func in SmartInk.swift -> SmartShape
            if shape != .none {
                let ideal = idealize(shape)           // free func -> [CGPoint]
                return SmartInkResult(replacement: makeStroke(from: ideal, like: stroke),
                                      recognized: recognized(from: shape))
            }
        }
        if doSmooth {
            let smoothed = smooth(raw)                // free func -> [CGPoint]
            return SmartInkResult(replacement: makeStroke(from: smoothed, like: stroke),
                                  recognized: nil)
        }
        return SmartInkResult(replacement: nil, recognized: nil)
    }

    // MARK: - Adapters

    private static func recognized(from shape: SmartShape) -> RecognizedShape? {
        switch shape {
        case .line:      return .line
        case .rectangle: return .rectangle
        case .ellipse:   return .ellipse
        case .triangle:  return .triangle
        case .arrow:     return .arrow
        case .none:      return nil
        }
    }

    /// Sample a PKStroke's path into drawing-space CGPoints.
    private static func points(from stroke: PKStroke) -> [CGPoint] {
        let t = stroke.transform
        var pts: [CGPoint] = []
        for p in stroke.path.interpolatedPoints(by: .distance(2.0)) {
            pts.append(t.isIdentity ? p.location : p.location.applying(t))
        }
        return pts
    }

    /// Build a new PKStroke through `pts`, reusing the template stroke's ink and
    /// per-point attributes so color/width/tool match what the user drew.
    private static func makeStroke(from pts: [CGPoint], like template: PKStroke) -> PKStroke {
        let ink = template.ink
        let sample = Array(template.path.interpolatedPoints(by: .distance(1.0))).first
        let size = sample?.size ?? CGSize(width: 3, height: 3)
        let opacity = sample?.opacity ?? 1
        let force = sample?.force ?? 1
        let azimuth = sample?.azimuth ?? 0
        let altitude = sample?.altitude ?? (.pi / 2)

        var strokePoints: [PKStrokePoint] = []
        strokePoints.reserveCapacity(pts.count)
        let dt = 0.01
        for (i, pt) in pts.enumerated() {
            strokePoints.append(PKStrokePoint(
                location: pt,
                timeOffset: Double(i) * dt,
                size: size,
                opacity: opacity,
                force: force,
                azimuth: azimuth,
                altitude: altitude))
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
        // Points are already in drawing space, so the new stroke uses identity transform.
        return PKStroke(ink: ink, path: path)
    }
}
