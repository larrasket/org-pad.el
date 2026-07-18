// SmartInk.swift
//
// org-pad v2 — smart-ink geometry engine (PURE MATH, no UIKit / PencilKit).
//
// Operates entirely on `[CGPoint]` (a stroke's sampled path). Everything here is
// deterministic, side-effect-free, and unit-testable off-device with `swift`.
// The on-device layer (PencilKit) is responsible only for:
//   1. extracting a stroke's points  (PKStrokePath.interpolatedPoints(by:)),
//   2. feeding them to `classifyShape` / `smooth`,
//   3. turning `idealize(shape:)` / `smooth(points:)` output back into a PKStroke.
//
// Design goals:
//   * Snap clean geometric shapes (line / rect / ellipse / triangle / arrow).
//   * De-jitter freehand ink without destroying legibility.
//   * NEVER snap real handwriting / scribbles -> return `.none` for those.
//
// Foundation gives us CGPoint / CGRect / CGFloat with no UI dependency. This
// compiles and runs under a bare `swift SmartInk.swift` on macOS.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Public shape model

/// The result of recognising a single stroke.
public enum SmartShape: Equatable {
    /// A straight segment.
    case line(from: CGPoint, to: CGPoint)
    /// An axis-aligned-ish rectangle. `rotation` is the corner-frame rotation in
    /// radians (0 for axis-aligned); the CGRect is expressed in the un-rotated
    /// frame and rotated about its center by `rotation` when idealised.
    case rectangle(CGRect, rotation: CGFloat)
    /// An ellipse inscribed in the bounding box.
    case ellipse(CGRect)
    /// A triangle given by its three corner points (in stroke order).
    case triangle([CGPoint])
    /// An arrow: a shaft plus arrow-head wings at `to`.
    case arrow(from: CGPoint, to: CGPoint, heads: [CGPoint])
    /// Not a recognised shape (scribble, handwriting, ambiguous). Do not snap.
    case none
}

// MARK: - Tunable tolerances (named constants so they are easy to tune on-device)

public enum SmartInkConfig {
    // --- Preprocessing ---
    /// RDP epsilon (in points) used when reducing a stroke to its "corner" polyline
    /// for shape analysis. Larger => fewer, coarser corners.
    public static var cornerRDPEpsilon: CGFloat = 8.0
    /// Points closer together than this (after resampling for analysis) are merged.
    public static var minSegmentLength: CGFloat = 4.0
    /// Number of points a stroke is resampled to before straightness / circularity math.
    public static var analysisSampleCount: Int = 64

    // --- Closedness ---
    /// A stroke is "closed" if the gap between its endpoints is <= this fraction of
    /// its bounding-box diagonal.
    public static var closedGapFraction: CGFloat = 0.28

    // --- Line ---
    /// Minimum R^2 of a total-least-squares line fit for `.line`.
    public static var lineMinR2: CGFloat = 0.985
    /// A stroke whose path length barely exceeds its endpoint distance is straight.
    /// length/chord must be <= this to be a line.
    public static var lineMaxLengthChordRatio: CGFloat = 1.12

    // --- Corners / polygon vertex detection ---
    /// A vertex is a "corner" if the turning angle there exceeds this (radians).
    /// ~40 degrees.
    public static var cornerMinAngle: CGFloat = 0.70
    /// Corners nearer than this fraction of the perimeter to another corner are merged.
    public static var cornerMergeFraction: CGFloat = 0.10

    // --- Rectangle ---
    /// Corner angles of a rectangle must be within this many radians of 90 degrees.
    public static var rectAngleTolerance: CGFloat = 0.45   // ~26 deg
    /// Opposite side lengths must match within this fraction.
    public static var rectSideMatchTolerance: CGFloat = 0.35

    // --- Triangle ---
    /// Interior angles must each be at least this (radians) — rejects degenerate slivers.
    public static var triangleMinAngle: CGFloat = 0.28     // ~16 deg

    // --- Ellipse ---
    /// Max coefficient-of-variation of the radius (distance from centroid) for a
    /// stroke to count as an ellipse/circle after normalising by the axis model.
    public static var ellipseMaxRadialCV: CGFloat = 0.18
    /// Fraction of the full 2π the stroke's angular sweep must cover to be a full
    /// ellipse (rejects arcs).
    public static var ellipseMinAngularCoverage: CGFloat = 0.80

    // --- Scribble / handwriting rejection ---
    /// If the stroke reverses direction more than this many times it is
    /// handwriting/scribble -> `.none`. (Cursive & letters oscillate a lot.)
    public static var maxDirectionReversals: Int = 6
    /// If total absolute turning (sum |Δangle|) exceeds this many full turns, it's
    /// a scribble -> `.none`.
    public static var maxTotalTurningTurns: CGFloat = 2.6
    /// A stroke must be at least this long (points) to be considered for snapping.
    public static var minStrokeLength: CGFloat = 24.0
    /// A stroke must have at least this many raw samples to classify.
    public static var minPointCount: Int = 6

    // --- Smoothing ---
    /// RDP epsilon used by `smooth` (much smaller than corner epsilon: preserve shape).
    public static var smoothRDPEpsilon: CGFloat = 1.2
    /// Target spacing (points) of the Catmull-Rom resample done by `smooth`.
    public static var smoothResampleSpacing: CGFloat = 3.0
}

// MARK: - Geometry helpers

@inline(__always) func opAdd(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
@inline(__always) func opSub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
@inline(__always) func opScale(_ a: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
@inline(__always) func opDot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
@inline(__always) func opCross(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.y - a.y * b.x }
@inline(__always) func opLen(_ a: CGPoint) -> CGFloat { (a.x * a.x + a.y * a.y).squareRoot() }
@inline(__always) func opDist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { opLen(opSub(a, b)) }

func polylineLength(_ pts: [CGPoint]) -> CGFloat {
    guard pts.count > 1 else { return 0 }
    var total: CGFloat = 0
    for i in 1..<pts.count { total += opDist(pts[i], pts[i - 1]) }
    return total
}

func boundingBox(_ pts: [CGPoint]) -> CGRect {
    guard let first = pts.first else { return .zero }
    var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
    for p in pts {
        minX = min(minX, p.x); minY = min(minY, p.y)
        maxX = max(maxX, p.x); maxY = max(maxY, p.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

func centroid(_ pts: [CGPoint]) -> CGPoint {
    guard !pts.isEmpty else { return .zero }
    var sx: CGFloat = 0, sy: CGFloat = 0
    for p in pts { sx += p.x; sy += p.y }
    return CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count))
}

/// Signed turning angle at vertex `b` for the path a->b->c, in (-π, π].
func turningAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
    let v1 = opSub(b, a), v2 = opSub(c, b)
    let l1 = opLen(v1), l2 = opLen(v2)
    if l1 < 1e-6 || l2 < 1e-6 { return 0 }
    let cross = opCross(v1, v2)
    let dot = opDot(v1, v2)
    return atan2(cross, dot)
}

/// Interior angle (0...π) at `b` in the corner a-b-c.
func interiorAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
    let v1 = opSub(a, b), v2 = opSub(c, b)
    let l1 = opLen(v1), l2 = opLen(v2)
    if l1 < 1e-6 || l2 < 1e-6 { return 0 }
    let cosv = max(-1, min(1, opDot(v1, v2) / (l1 * l2)))
    return acos(cosv)
}

// MARK: - resample

/// Resample a polyline to points that are (approximately) `spacing` apart along
/// arc length. Preserves the first and last points. `spacing` must be > 0.
public func resample(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
    guard points.count > 1, spacing > 0 else { return points }
    var result: [CGPoint] = [points[0]]
    var prev = points[0]
    var distSoFar: CGFloat = 0
    var i = 1
    while i < points.count {
        let curr = points[i]
        let segLen = opDist(prev, curr)
        if segLen < 1e-9 { i += 1; continue }
        if distSoFar + segLen >= spacing {
            let t = (spacing - distSoFar) / segLen
            let np = CGPoint(x: prev.x + t * (curr.x - prev.x),
                             y: prev.y + t * (curr.y - prev.y))
            result.append(np)
            prev = np
            distSoFar = 0
            // do NOT advance i: keep sampling the same segment
        } else {
            distSoFar += segLen
            prev = curr
            i += 1
        }
    }
    // Guarantee the true endpoint is present.
    if let last = points.last, opDist(result.last ?? last, last) > 1e-6 {
        result.append(last)
    }
    return result
}

// MARK: - Ramer-Douglas-Peucker

/// Simplify a polyline with the Ramer-Douglas-Peucker algorithm. Endpoints are
/// always preserved.
public func rdpSimplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
    guard points.count > 2 else { return points }
    var keep = [Bool](repeating: false, count: points.count)
    keep[0] = true
    keep[points.count - 1] = true
    rdpRecurse(points, 0, points.count - 1, epsilon, &keep)
    var out: [CGPoint] = []
    for (i, p) in points.enumerated() where keep[i] { out.append(p) }
    return out
}

private func rdpRecurse(_ pts: [CGPoint], _ first: Int, _ last: Int,
                        _ eps: CGFloat, _ keep: inout [Bool]) {
    guard last > first + 1 else { return }
    let a = pts[first], b = pts[last]
    let ab = opSub(b, a)
    let abLen = opLen(ab)
    var maxDist: CGFloat = -1
    var idx = -1
    for i in (first + 1)..<last {
        let dist: CGFloat
        if abLen < 1e-9 {
            dist = opDist(pts[i], a)
        } else {
            dist = abs(opCross(ab, opSub(pts[i], a))) / abLen
        }
        if dist > maxDist { maxDist = dist; idx = i }
    }
    if maxDist > eps && idx > first {
        keep[idx] = true
        rdpRecurse(pts, first, idx, eps, &keep)
        rdpRecurse(pts, idx, last, eps, &keep)
    }
}

// MARK: - Catmull-Rom smoothing resample

/// Produce a smoothed, evenly-resampled polyline through `points` using a
/// centripetal-ish Catmull-Rom spline evaluated at `spacing` intervals.
/// Endpoints are preserved exactly.
func catmullRomResample(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
    guard points.count >= 3, spacing > 0 else { return points }
    // Pad with duplicated endpoints so every segment has 4 control points.
    var p = points
    p.insert(points.first!, at: 0)
    p.append(points.last!)
    var out: [CGPoint] = [points.first!]
    for i in 1..<(p.count - 2) {
        let p0 = p[i - 1], p1 = p[i], p2 = p[i + 1], p3 = p[i + 2]
        let segLen = opDist(p1, p2)
        let steps = max(1, Int((segLen / spacing).rounded()))
        for s in 1...steps {
            let t = CGFloat(s) / CGFloat(steps)
            out.append(catmullRomPoint(p0, p1, p2, p3, t))
        }
    }
    // Snap final point to the exact endpoint.
    out[out.count - 1] = points.last!
    return out
}

@inline(__always)
func catmullRomPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
    let t2 = t * t, t3 = t2 * t
    let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t +
                   (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
                   (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
    let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t +
                   (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
                   (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
    return CGPoint(x: x, y: y)
}

// MARK: - smooth

/// De-jitter a freehand stroke. Strategy:
///   1. RDP simplify with a *small* epsilon to drop sub-pixel jitter samples
///      while preserving genuine shape features.
///   2. Catmull-Rom resample the simplified path for smooth, evenly-spaced points.
/// Endpoints are preserved exactly. Handwriting stays legible because the RDP
/// epsilon is small and Catmull-Rom interpolates (does not cut corners hard).
public func smooth(_ points: [CGPoint]) -> [CGPoint] {
    guard points.count > 2 else { return points }
    let simplified = rdpSimplify(points, epsilon: SmartInkConfig.smoothRDPEpsilon)
    guard simplified.count >= 3 else { return simplified }
    return catmullRomResample(simplified, spacing: SmartInkConfig.smoothResampleSpacing)
}

// MARK: - Stroke shape metrics

/// Count how many times the stroke's travel direction reverses (dot of
/// consecutive segment vectors goes negative). A strong handwriting signal.
func directionReversals(_ pts: [CGPoint]) -> Int {
    guard pts.count > 2 else { return 0 }
    var reversals = 0
    var prev: CGPoint? = nil
    for i in 1..<pts.count {
        let v = opSub(pts[i], pts[i - 1])
        if opLen(v) < 1e-6 { continue }
        if let pv = prev, opDot(pv, v) < 0 { reversals += 1 }
        prev = v
    }
    return reversals
}

/// Sum of absolute turning angle along the path (radians). A scribble accumulates
/// a large value; a clean shape stays modest.
func totalAbsoluteTurning(_ pts: [CGPoint]) -> CGFloat {
    guard pts.count > 2 else { return 0 }
    var total: CGFloat = 0
    for i in 1..<(pts.count - 1) {
        total += abs(turningAngle(pts[i - 1], pts[i], pts[i + 1]))
    }
    return total
}

/// R^2 of a total-least-squares (orthogonal) line fit — how well the points lie
/// on a single straight line. 1.0 = perfectly straight.
func lineFitR2(_ pts: [CGPoint]) -> CGFloat {
    guard pts.count > 2 else { return 1 }
    let c = centroid(pts)
    var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
    for p in pts {
        let dx = p.x - c.x, dy = p.y - c.y
        sxx += dx * dx; syy += dy * dy; sxy += dx * dy
    }
    let total = sxx + syy
    if total < 1e-9 { return 1 }
    // Eigenvalues of the 2x2 covariance matrix.
    let tr = sxx + syy
    let det = sxx * syy - sxy * sxy
    let disc = max(0, tr * tr / 4 - det)
    let lambdaMax = tr / 2 + disc.squareRoot()
    let lambdaMin = tr / 2 - disc.squareRoot()
    // Fraction of variance explained by the dominant axis.
    let explained = lambdaMax / (lambdaMax + lambdaMin)
    return explained
}

// MARK: - Corner detection

/// Detect polygon corners: resample coarsely, RDP-simplify, then keep vertices
/// whose turning angle exceeds `cornerMinAngle`. Merges near-duplicate corners.
/// Returns the ordered corner points (excluding an implicit closing duplicate).
func detectCorners(_ pts: [CGPoint]) -> [CGPoint] {
    guard pts.count >= 3 else { return pts }
    let simplified = rdpSimplify(pts, epsilon: SmartInkConfig.cornerRDPEpsilon)
    guard simplified.count >= 3 else { return simplified }

    // Determine closedness to know whether to consider the wrap-around vertex.
    let bb = boundingBox(pts)
    let diag = opLen(CGPoint(x: bb.width, y: bb.height))
    let endpointGap = opDist(pts.first!, pts.last!)
    let closed = diag > 1e-6 && (endpointGap / diag) <= SmartInkConfig.closedGapFraction

    var corners: [CGPoint] = []
    let n = simplified.count
    let range = closed ? (0..<n) : (1..<(n - 1))
    for i in range {
        let prev = simplified[(i - 1 + n) % n]
        let curr = simplified[i]
        let next = simplified[(i + 1) % n]
        let ang = abs(turningAngle(prev, curr, next))
        if ang >= SmartInkConfig.cornerMinAngle {
            corners.append(curr)
        }
    }

    // Merge corners closer than cornerMergeFraction of the perimeter.
    let perim = polylineLength(simplified)
    let mergeDist = perim * SmartInkConfig.cornerMergeFraction
    var merged: [CGPoint] = []
    for c in corners {
        if let last = merged.last, opDist(last, c) < mergeDist { continue }
        merged.append(c)
    }
    // Also merge first/last if closed and they coincide.
    if closed, merged.count > 1,
       opDist(merged.first!, merged.last!) < mergeDist {
        merged.removeLast()
    }
    return merged
}

// MARK: - classifyShape

/// Classify a raw sampled stroke into a `SmartShape`. Returns `.none` for
/// handwriting / scribbles / ambiguous input (the critical no-false-positive path).
public func classifyShape(_ rawPoints: [CGPoint]) -> SmartShape {
    // --- Guards ---
    guard rawPoints.count >= SmartInkConfig.minPointCount else { return .none }
    let strokeLen = polylineLength(rawPoints)
    guard strokeLen >= SmartInkConfig.minStrokeLength else { return .none }

    let bb = boundingBox(rawPoints)
    let diag = opLen(CGPoint(x: bb.width, y: bb.height))
    guard diag > 1e-6 else { return .none }

    // Resample uniformly for stable metrics.
    let spacing = max(SmartInkConfig.minSegmentLength, strokeLen / CGFloat(SmartInkConfig.analysisSampleCount))
    let pts = resample(rawPoints, spacing: spacing)
    guard pts.count >= 3 else { return .none }

    // --- Scribble / handwriting rejection (do this before anything snaps) ---
    let reversals = directionReversals(pts)
    let turning = totalAbsoluteTurning(pts)
    let turns = turning / (2 * .pi)
    let isScribble = reversals > SmartInkConfig.maxDirectionReversals
        || turns > SmartInkConfig.maxTotalTurningTurns

    // --- Closedness ---
    let endpointGap = opDist(rawPoints.first!, rawPoints.last!)
    let closed = (endpointGap / diag) <= SmartInkConfig.closedGapFraction

    // --- Line (open, very straight) ---
    if !closed {
        let r2 = lineFitR2(pts)
        let chord = opDist(rawPoints.first!, rawPoints.last!)
        let lenChord = chord > 1e-6 ? strokeLen / chord : .infinity
        if r2 >= SmartInkConfig.lineMinR2 && lenChord <= SmartInkConfig.lineMaxLengthChordRatio {
            return .line(from: rawPoints.first!, to: rawPoints.last!)
        }
    }

    // If clearly a scribble, stop here (no polygon/ellipse snapping).
    if isScribble { return .none }

    // --- Corner-based polygon detection ---
    let corners = detectCorners(rawPoints)

    if closed {
        // Rectangle: 4 corners, ~90 deg angles, matched opposite sides.
        if corners.count == 4, let rect = rectangleFrom(corners) {
            return rect
        }
        // Triangle: 3 corners, all angles reasonable.
        if corners.count == 3, isValidTriangle(corners) {
            return .triangle(corners)
        }
        // Ellipse: few/no sharp corners + good circular fit.
        if corners.count <= 2, let ell = ellipseFrom(pts, bb: bb) {
            return ell
        }
    } else {
        // Open stroke that isn't a line: possibly an arrow (shaft + head at end).
        if let arrow = arrowFrom(rawPoints) {
            return arrow
        }
    }

    return .none
}

// MARK: - Rectangle construction

/// Build a `.rectangle` from four ordered corners, validating angles & sides.
/// Supports rotation: fits the corner cloud with a minimum-area-ish oriented box
/// derived from the dominant edge direction.
func rectangleFrom(_ corners: [CGPoint]) -> SmartShape? {
    guard corners.count == 4 else { return nil }
    // Validate corner angles ~90 deg.
    for i in 0..<4 {
        let a = corners[(i + 3) % 4], b = corners[i], c = corners[(i + 1) % 4]
        let ang = interiorAngle(a, b, c)
        if abs(ang - .pi / 2) > SmartInkConfig.rectAngleTolerance { return nil }
    }
    // Side lengths; opposite sides must match.
    let s0 = opDist(corners[0], corners[1])
    let s1 = opDist(corners[1], corners[2])
    let s2 = opDist(corners[2], corners[3])
    let s3 = opDist(corners[3], corners[0])
    func matched(_ a: CGFloat, _ b: CGFloat) -> Bool {
        let m = max(a, b); if m < 1e-6 { return true }
        return abs(a - b) / m <= SmartInkConfig.rectSideMatchTolerance
    }
    if !matched(s0, s2) || !matched(s1, s3) { return nil }

    // Rotation from the first edge.
    let edge = opSub(corners[1], corners[0])
    var rotation = atan2(edge.y, edge.x)
    // Normalise rotation into (-π/4, π/4] so a near-axis-aligned box reports ~0.
    while rotation > .pi / 4 { rotation -= .pi / 2 }
    while rotation <= -(.pi / 4) { rotation += .pi / 2 }

    let center = centroid(corners)
    // Express corners in the un-rotated frame to find width/height.
    let cosr = cos(-rotation), sinr = sin(-rotation)
    var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
    for c in corners {
        let d = opSub(c, center)
        let rx = d.x * cosr - d.y * sinr
        let ry = d.x * sinr + d.y * cosr
        minX = min(minX, rx); minY = min(minY, ry)
        maxX = max(maxX, rx); maxY = max(maxY, ry)
    }
    let rect = CGRect(x: center.x + minX, y: center.y + minY,
                      width: maxX - minX, height: maxY - minY)
    return .rectangle(rect, rotation: abs(rotation) < 0.02 ? 0 : rotation)
}

// MARK: - Triangle validation

func isValidTriangle(_ corners: [CGPoint]) -> Bool {
    guard corners.count == 3 else { return false }
    for i in 0..<3 {
        let a = corners[(i + 2) % 3], b = corners[i], c = corners[(i + 1) % 3]
        let ang = interiorAngle(a, b, c)
        if ang < SmartInkConfig.triangleMinAngle { return false }
    }
    // Angles of a triangle sum to ~π; guard against collinear degeneracy.
    let sum = interiorAngle(corners[2], corners[0], corners[1])
            + interiorAngle(corners[0], corners[1], corners[2])
            + interiorAngle(corners[1], corners[2], corners[0])
    return abs(sum - .pi) < 0.5
}

// MARK: - Ellipse construction

/// Fit an ellipse to a closed stroke by checking radial consistency in the
/// bounding-box-normalised frame. Returns `.ellipse` or nil.
func ellipseFrom(_ pts: [CGPoint], bb: CGRect) -> SmartShape? {
    guard bb.width > 1e-6, bb.height > 1e-6 else { return nil }
    let cx = bb.midX, cy = bb.midY
    let a = bb.width / 2, b = bb.height / 2

    // Normalise each point onto the unit circle via the axis model; a true
    // ellipse maps every point to radius ~1.
    var radii: [CGFloat] = []
    radii.reserveCapacity(pts.count)
    var angles: [CGFloat] = []
    for p in pts {
        let nx = (p.x - cx) / a
        let ny = (p.y - cy) / b
        radii.append((nx * nx + ny * ny).squareRoot())
        angles.append(atan2(ny, nx))
    }
    let meanR = radii.reduce(0, +) / CGFloat(radii.count)
    guard meanR > 1e-6 else { return nil }
    var variance: CGFloat = 0
    for r in radii { let d = r - meanR; variance += d * d }
    variance /= CGFloat(radii.count)
    let cv = variance.squareRoot() / meanR
    if cv > SmartInkConfig.ellipseMaxRadialCV { return nil }

    // Angular coverage: reject arcs. Bucket angles into sectors, count occupancy.
    let sectors = 24
    var occupied = [Bool](repeating: false, count: sectors)
    for ang in angles {
        var norm = ang
        while norm < 0 { norm += 2 * .pi }
        let idx = min(sectors - 1, Int(norm / (2 * .pi) * CGFloat(sectors)))
        occupied[idx] = true
    }
    let coverage = CGFloat(occupied.filter { $0 }.count) / CGFloat(sectors)
    if coverage < SmartInkConfig.ellipseMinAngularCoverage { return nil }

    return .ellipse(bb)
}

// MARK: - Arrow construction

/// Recognise an arrow: a long, mostly-straight shaft, then a small head near the
/// far end where the pen doubles back (the V wings). A hand-drawn arrow head is
/// exactly a back-and-forth motion, so we detect the head as the point where the
/// path *first* leaves the straight shaft line by a meaningful amount, and then
/// verify that the tail after that point folds back toward the shaft.
func arrowFrom(_ pts: [CGPoint]) -> SmartShape? {
    guard pts.count >= 6 else { return nil }
    let start = pts.first!
    // The tip is the point on the path farthest along the dominant shaft direction
    // (the corner where the head begins). We take the extreme point from `start`.
    var tip = pts.last!
    var tipIdx = pts.count - 1
    var maxD: CGFloat = 0
    for (i, p) in pts.enumerated() {
        let d = opDist(p, start)
        if d > maxD { maxD = d; tip = p; tipIdx = i }
    }
    let shaftVec = opSub(tip, start)
    let shaftLen = opLen(shaftVec)
    guard shaftLen > SmartInkConfig.minStrokeLength else { return nil }
    // Need a real head: some path after the tip.
    guard tipIdx < pts.count - 1 else { return nil }
    let shaftDir = opScale(shaftVec, 1 / shaftLen)

    // Shaft (start..tip) must be reasonably straight.
    let shaftPts = Array(pts[0...tipIdx])
    if shaftPts.count >= 3 {
        // Straightness by max perpendicular deviation relative to shaft length.
        var maxPerp: CGFloat = 0
        for p in shaftPts {
            let rel = opSub(p, start)
            let perp = abs(opCross(shaftDir, rel))
            maxPerp = max(maxPerp, perp)
        }
        if maxPerp / shaftLen > 0.18 { return nil }
    }

    // Head = the tail after the tip. Collect the extreme wing points: the points
    // in the tail that deviate most to each side of the shaft line, and confirm
    // they fold backward (component opposite the shaft direction).
    let tail = Array(pts[tipIdx...])
    guard tail.count >= 2 else { return nil }
    var wingLeft: CGPoint? = nil, wingRight: CGPoint? = nil
    var maxLeft: CGFloat = 0, maxRight: CGFloat = 0
    var sawBackward = false
    for p in tail {
        let rel = opSub(p, tip)
        let along = opDot(rel, shaftDir)          // negative => points back down the shaft
        let side = opCross(shaftDir, rel)         // signed perpendicular
        if along < -1 { sawBackward = true }
        if side > maxLeft { maxLeft = side; wingLeft = p }
        if -side > maxRight { maxRight = -side; wingRight = p }
    }
    guard sawBackward else { return nil }
    // The head must be modest relative to the shaft (not another long segment).
    let headSpan = opDist(tip, tail.last!)
    guard headSpan < shaftLen * 0.6 else { return nil }

    var heads: [CGPoint] = []
    if let l = wingLeft { heads.append(l) }
    if let r = wingRight { heads.append(r) }
    guard !heads.isEmpty else { return nil }

    return .arrow(from: start, to: tip, heads: heads)
}

// MARK: - idealize

/// Turn a recognised shape back into a clean polyline that can be rebuilt into a
/// PKStroke on-device. Closed shapes return a closed polyline (first == last).
public func idealize(_ shape: SmartShape) -> [CGPoint] {
    switch shape {
    case .none:
        return []

    case let .line(from, to):
        return [from, to]

    case let .rectangle(rect, rotation):
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
        let cosr = cos(rotation), sinr = sin(rotation)
        func rot(_ p: CGPoint) -> CGPoint {
            let d = opSub(p, c)
            return CGPoint(x: c.x + d.x * cosr - d.y * sinr,
                           y: c.y + d.x * sinr + d.y * cosr)
        }
        let r = corners.map(rot)
        return [r[0], r[1], r[2], r[3], r[0]]

    case let .ellipse(rect):
        let cx = rect.midX, cy = rect.midY
        let a = rect.width / 2, b = rect.height / 2
        let steps = 48
        var out: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            out.append(CGPoint(x: cx + a * cos(t), y: cy + b * sin(t)))
        }
        return out

    case let .triangle(corners):
        guard corners.count == 3 else { return corners }
        return [corners[0], corners[1], corners[2], corners[0]]

    case let .arrow(from, to, _):
        // Shaft + two symmetric arrow-head wings computed from geometry.
        let shaft = opSub(to, from)
        let len = opLen(shaft)
        guard len > 1e-6 else { return [from, to] }
        let dir = opScale(shaft, 1 / len)
        let headLen = min(len * 0.25, 30)
        let headAngle: CGFloat = 0.45   // ~26 deg per wing
        func rotate(_ v: CGPoint, _ ang: CGFloat) -> CGPoint {
            CGPoint(x: v.x * cos(ang) - v.y * sin(ang),
                    y: v.x * sin(ang) + v.y * cos(ang))
        }
        let back = opScale(dir, -headLen)
        let wing1 = opAdd(to, rotate(back, headAngle))
        let wing2 = opAdd(to, rotate(back, -headAngle))
        // Polyline: shaft, then wing1->tip->wing2 to draw the head.
        return [from, to, wing1, to, wing2]
    }
}
