// verify_smartink.swift
//
// Off-device verification of the SmartInk geometry engine.
//
// This file has top-level statements, so it must be the compilation unit's
// "main" file. `swift verify_smartink.swift SmartInk.swift` does NOT work (the
// swift interpreter treats the 2nd path as a program argument, not a source).
// Compile the two files together instead:
//
//     cp verify_smartink.swift main.swift \
//       && swiftc SmartInk.swift main.swift -o /tmp/smartink_verify \
//       && /tmp/smartink_verify ; rm -f main.swift
//
// or just run the bundled script:  ./run_verify.sh

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Tiny test harness

var passCount = 0
var failCount = 0

func check(_ cond: Bool, _ label: String) {
    if cond {
        passCount += 1
        print("PASS: \(label)")
    } else {
        failCount += 1
        print("FAIL: \(label)")
    }
}

// Deterministic pseudo-noise so runs are reproducible. Reset per test so each
// stroke builder sees the same noise sequence regardless of test order.
var rngState: UInt64 = 0x9E3779B97F4A7C15
func resetRNG() { rngState = 0x9E3779B97F4A7C15 }
func noise(_ amp: CGFloat) -> CGFloat {
    rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
    let u = CGFloat(rngState >> 33) / CGFloat(UInt64(1) << 31)  // 0..2
    return (u - 1.0) * amp                                       // -amp..amp
}

// MARK: - Stroke builders

/// A line between two points densely sampled with small perpendicular jitter.
func buildRoughLine(from a: CGPoint, to b: CGPoint, samples: Int, jitter: CGFloat) -> [CGPoint] {
    var pts: [CGPoint] = []
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples)
        let x = a.x + (b.x - a.x) * t + noise(jitter)
        let y = a.y + (b.y - a.y) * t + noise(jitter)
        pts.append(CGPoint(x: x, y: y))
    }
    return pts
}

/// A rough rectangle: walk the 4 sides with samples + noise. Closed-ish.
func buildRoughRect(_ rect: CGRect, perSide: Int, jitter: CGFloat) -> [CGPoint] {
    let corners = [
        CGPoint(x: rect.minX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY),
        CGPoint(x: rect.minX, y: rect.maxY),
    ]
    var pts: [CGPoint] = []
    for i in 0..<4 {
        let a = corners[i], b = corners[(i + 1) % 4]
        for j in 0..<perSide {
            let t = CGFloat(j) / CGFloat(perSide)
            pts.append(CGPoint(x: a.x + (b.x - a.x) * t + noise(jitter),
                               y: a.y + (b.y - a.y) * t + noise(jitter)))
        }
    }
    // close back near the start
    pts.append(CGPoint(x: corners[0].x + noise(jitter), y: corners[0].y + noise(jitter)))
    return pts
}

/// A rough circle/ellipse.
func buildRoughEllipse(center: CGPoint, rx: CGFloat, ry: CGFloat, samples: Int, jitter: CGFloat) -> [CGPoint] {
    var pts: [CGPoint] = []
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        pts.append(CGPoint(x: center.x + rx * cos(t) + noise(jitter),
                           y: center.y + ry * sin(t) + noise(jitter)))
    }
    return pts
}

/// A rough triangle (3 corners), closed.
func buildRoughTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, perSide: Int, jitter: CGFloat) -> [CGPoint] {
    let corners = [a, b, c]
    var pts: [CGPoint] = []
    for i in 0..<3 {
        let p = corners[i], q = corners[(i + 1) % 3]
        for j in 0..<perSide {
            let t = CGFloat(j) / CGFloat(perSide)
            pts.append(CGPoint(x: p.x + (q.x - p.x) * t + noise(jitter),
                               y: p.y + (q.y - p.y) * t + noise(jitter)))
        }
    }
    pts.append(CGPoint(x: a.x + noise(jitter), y: a.y + noise(jitter)))
    return pts
}

/// An arrow: straight shaft + a V head at the end.
func buildArrow(from a: CGPoint, to b: CGPoint, jitter: CGFloat) -> [CGPoint] {
    var pts = buildRoughLine(from: a, to: b, samples: 30, jitter: jitter)
    // head wings
    let shaft = CGPoint(x: b.x - a.x, y: b.y - a.y)
    let len = (shaft.x * shaft.x + shaft.y * shaft.y).squareRoot()
    let dir = CGPoint(x: shaft.x / len, y: shaft.y / len)
    let headLen = min(len * 0.22, 28)
    func rot(_ v: CGPoint, _ ang: CGFloat) -> CGPoint {
        CGPoint(x: v.x * cos(ang) - v.y * sin(ang), y: v.x * sin(ang) + v.y * cos(ang))
    }
    let back = CGPoint(x: -dir.x * headLen, y: -dir.y * headLen)
    let wing1 = CGPoint(x: b.x + rot(back, 0.5).x, y: b.y + rot(back, 0.5).y)
    let wing2 = CGPoint(x: b.x + rot(back, -0.5).x, y: b.y + rot(back, -0.5).y)
    // draw: ...to tip, out to wing1, back to tip, out to wing2
    for w in [wing1, b, wing2] {
        pts.append(CGPoint(x: w.x + noise(jitter), y: w.y + noise(jitter)))
    }
    return pts
}

/// Dense wavy scribble (mock cursive): a sine wave with many oscillations plus
/// small vertical loops — the canonical "must NOT snap" case.
func buildScribble() -> [CGPoint] {
    var pts: [CGPoint] = []
    var x: CGFloat = 0
    // Mock cursive: advance in x while oscillating up/down many times, with loops.
    for i in 0..<220 {
        let t = CGFloat(i)
        x += 1.6
        let y = 40 * sin(t * 0.55) + 12 * sin(t * 1.9) + noise(1.5)
        pts.append(CGPoint(x: x, y: y + 100))
    }
    return pts
}

/// A tighter "handwritten word" mock: several letter-like humps with pen
/// direction reversals (like writing "mmm" / "www").
func buildCursiveWord() -> [CGPoint] {
    var pts: [CGPoint] = []
    var x: CGFloat = 0
    for hump in 0..<5 {
        let baseX = CGFloat(hump) * 30
        // up-stroke
        for j in 0...10 {
            let t = CGFloat(j) / 10
            x = baseX + t * 15
            pts.append(CGPoint(x: x, y: 100 - 35 * sin(t * .pi) + noise(1.0)))
        }
        // down-stroke (reverses vertical direction)
        for j in 0...10 {
            let t = CGFloat(j) / 10
            x = baseX + 15 + t * 15
            pts.append(CGPoint(x: x, y: 100 - 20 * sin((1 - t) * .pi) + noise(1.0)))
        }
    }
    return pts
}

// MARK: - Shape name helper

func shapeName(_ s: SmartShape) -> String {
    switch s {
    case .line: return "line"
    case .rectangle: return "rectangle"
    case .ellipse: return "ellipse"
    case .triangle: return "triangle"
    case .arrow: return "arrow"
    case .none: return "none"
    }
}

// MARK: - Tests

/// Wrap a test block so it starts from a known RNG state (order-independent).
func testCase(_ body: () -> Void) { resetRNG(); body() }

func runTests() {
print("=== SmartInk verification ===")

// 1. Rough rectangle -> .rectangle
testCase {
    let stroke = buildRoughRect(CGRect(x: 100, y: 100, width: 220, height: 140), perSide: 22, jitter: 4)
    let shape = classifyShape(stroke)
    check({ if case .rectangle = shape { return true }; return false }(),
          "rough rectangle classifies as .rectangle (got \(shapeName(shape)))")
}

// 1b. Rotated rectangle -> .rectangle with rotation != 0
testCase {
    // Build an axis-aligned rect then rotate all points ~20 degrees.
    let base = buildRoughRect(CGRect(x: -100, y: -60, width: 200, height: 120), perSide: 22, jitter: 3)
    let ang: CGFloat = 0.35
    let rotated = base.map { p -> CGPoint in
        CGPoint(x: p.x * cos(ang) - p.y * sin(ang) + 300,
                y: p.x * sin(ang) + p.y * cos(ang) + 300)
    }
    let shape = classifyShape(rotated)
    check({ if case .rectangle = shape { return true }; return false }(),
          "rotated rectangle still classifies as .rectangle (got \(shapeName(shape)))")
}

// 2. Rough circle -> .ellipse
testCase {
    let stroke = buildRoughEllipse(center: CGPoint(x: 200, y: 200), rx: 90, ry: 90, samples: 60, jitter: 4)
    let shape = classifyShape(stroke)
    check({ if case .ellipse = shape { return true }; return false }(),
          "rough circle classifies as .ellipse (got \(shapeName(shape)))")
}

// 2b. Rough ellipse (non-circular) -> .ellipse
testCase {
    let stroke = buildRoughEllipse(center: CGPoint(x: 200, y: 200), rx: 130, ry: 70, samples: 60, jitter: 4)
    let shape = classifyShape(stroke)
    check({ if case .ellipse = shape { return true }; return false }(),
          "rough ellipse classifies as .ellipse (got \(shapeName(shape)))")
}

// 3. Straight-ish line -> .line
testCase {
    let stroke = buildRoughLine(from: CGPoint(x: 50, y: 300), to: CGPoint(x: 400, y: 330), samples: 40, jitter: 2.5)
    let shape = classifyShape(stroke)
    check({ if case .line = shape { return true }; return false }(),
          "straight-ish line classifies as .line (got \(shapeName(shape)))")
}

// 4. Triangle -> .triangle
testCase {
    let stroke = buildRoughTriangle(CGPoint(x: 200, y: 60),
                                    CGPoint(x: 340, y: 300),
                                    CGPoint(x: 60, y: 300),
                                    perSide: 26, jitter: 4)
    let shape = classifyShape(stroke)
    check({ if case .triangle = shape { return true }; return false }(),
          "rough triangle classifies as .triangle (got \(shapeName(shape)))")
}

// 5. Arrow -> .arrow
testCase {
    let stroke = buildArrow(from: CGPoint(x: 60, y: 200), to: CGPoint(x: 380, y: 210), jitter: 2.0)
    let shape = classifyShape(stroke)
    check({ if case .arrow = shape { return true }; return false }(),
          "arrow classifies as .arrow (got \(shapeName(shape)))")
}

// 6. CRITICAL — dense wavy scribble -> .none
testCase {
    let stroke = buildScribble()
    let shape = classifyShape(stroke)
    check(shape == .none, "dense wavy scribble -> .none (NO false positive) (got \(shapeName(shape)))")
}

// 6b. CRITICAL — mock cursive word -> .none
testCase {
    let stroke = buildCursiveWord()
    let shape = classifyShape(stroke)
    check(shape == .none, "mock cursive word -> .none (NO false positive) (got \(shapeName(shape)))")
}

// 6c. CRITICAL — a random tight squiggle -> .none
testCase {
    var pts: [CGPoint] = []
    for i in 0..<160 {
        let t = CGFloat(i)
        pts.append(CGPoint(x: 100 + t * 1.2 + 15 * sin(t * 0.9),
                           y: 100 + 30 * cos(t * 0.7) + 18 * sin(t * 2.3)))
    }
    let shape = classifyShape(pts)
    check(shape == .none, "tight squiggle -> .none (got \(shapeName(shape)))")
}

// 6d. CRITICAL — letter "S" (two opposing arcs) -> .none
testCase {
    var pts: [CGPoint] = []
    // top arc then bottom arc, opposite curvature — classic S.
    for j in 0...30 {
        let t = CGFloat(j) / 30 * .pi
        pts.append(CGPoint(x: 100 + 25 * cos(t) + noise(1), y: 60 - 20 * sin(t) + noise(1)))
    }
    for j in 0...30 {
        let t = CGFloat(j) / 30 * .pi
        pts.append(CGPoint(x: 100 - 25 * cos(t) + noise(1), y: 100 + 20 * sin(t) + noise(1)))
    }
    let shape = classifyShape(pts)
    check(shape == .none, "letter 'S' -> .none (got \(shapeName(shape)))")
}

// 6e. CRITICAL — a half-circle arc must NOT become an ellipse.
testCase {
    var pts: [CGPoint] = []
    for j in 0...40 {
        let t = CGFloat(j) / 40 * .pi   // only 180 degrees
        pts.append(CGPoint(x: 200 + 80 * cos(t) + noise(1.5), y: 200 + 80 * sin(t) + noise(1.5)))
    }
    let shape = classifyShape(pts)
    check(shapeName(shape) != "ellipse", "half-circle arc is NOT an ellipse (got \(shapeName(shape)))")
}

// 6f. CRITICAL — spiral (over-curved) -> .none, never ellipse.
testCase {
    var pts: [CGPoint] = []
    for j in 0...120 {
        let t = CGFloat(j) / 120 * 4 * .pi   // two full turns, growing radius
        let r = 20 + CGFloat(j) * 0.7
        pts.append(CGPoint(x: 200 + r * cos(t), y: 200 + r * sin(t)))
    }
    let shape = classifyShape(pts)
    check(shape == .none, "spiral -> .none (got \(shapeName(shape)))")
}

// 7. Too-few-points / too-short -> .none
testCase {
    check(classifyShape([]) == .none, "empty stroke -> .none")
    check(classifyShape([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]) == .none, "2-point stroke -> .none")
    let tiny = buildRoughLine(from: .zero, to: CGPoint(x: 5, y: 0), samples: 8, jitter: 0.1)
    check(classifyShape(tiny) == .none, "very short stroke -> .none")
}

// 8. resample: even spacing + endpoints preserved
testCase {
    let line = buildRoughLine(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), samples: 50, jitter: 0)
    let rs = resample(line, spacing: 10)
    check(rs.first == line.first, "resample preserves first point")
    // last point within spacing of true end
    let endGap = abs((rs.last?.x ?? 0) - 100)
    check(endGap < 10.001, "resample preserves endpoint (gap \(endGap))")
    // spacings roughly even
    var maxDev: CGFloat = 0
    for i in 1..<(rs.count - 1) {
        let d = abs(rs[i].x - rs[i - 1].x)
        maxDev = max(maxDev, abs(d - 10))
    }
    check(maxDev < 1.5, "resample spacing ~even (max dev \(maxDev))")
}

// 9. smooth: reduces total turning + preserves endpoints
testCase {
    // Jittery near-straight line: lots of small-angle noise.
    let jittery = buildRoughLine(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 300, y: 0), samples: 120, jitter: 3.0)
    let before = totalAbsoluteTurning(jittery)
    let smoothed = smooth(jittery)
    let after = totalAbsoluteTurning(smoothed)
    check(smoothed.first == jittery.first, "smooth preserves first point")
    check(smoothed.last == jittery.last, "smooth preserves last point")
    check(after < before, "smooth reduces total angle variation (\(before) -> \(after))")
    print("  info: turning before=\(before) after=\(after), points \(jittery.count)->\(smoothed.count)")
}

// 9b. smooth on a wavy scribble keeps it legible (endpoints exact, still wavy)
testCase {
    let scribble = buildScribble()
    let smoothed = smooth(scribble)
    check(smoothed.first == scribble.first && smoothed.last == scribble.last,
          "smooth preserves scribble endpoints")
    // It should still classify as .none after smoothing (we never snap handwriting).
    check(classifyShape(smoothed) == .none, "smoothed scribble still -> .none")
}

// 10. idealize round-trips into sane polylines
testCase {
    let rect = SmartShape.rectangle(CGRect(x: 0, y: 0, width: 100, height: 60), rotation: 0)
    let poly = idealize(rect)
    check(poly.count == 5 && poly.first == poly.last, "idealize(rectangle) -> closed 5-point polyline")

    let ell = idealize(.ellipse(CGRect(x: 0, y: 0, width: 100, height: 60)))
    check(ell.count > 10, "idealize(ellipse) -> dense polyline (\(ell.count) pts)")

    let ln = idealize(.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10)))
    check(ln.count == 2, "idealize(line) -> 2 points")

    let tri = idealize(.triangle([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 5, y: 10)]))
    check(tri.count == 4 && tri.first == tri.last, "idealize(triangle) -> closed 4-point polyline")

    let arr = idealize(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), heads: []))
    check(arr.count == 5, "idealize(arrow) -> shaft+head polyline (\(arr.count) pts)")

    check(idealize(.none).isEmpty, "idealize(none) -> empty")
}

// 11. rdpSimplify reduces point count, keeps endpoints
testCase {
    let dense = buildRoughLine(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 0), samples: 200, jitter: 0.5)
    let simp = rdpSimplify(dense, epsilon: 2.0)
    check(simp.count < dense.count, "rdpSimplify reduces point count (\(dense.count)->\(simp.count))")
    check(simp.first == dense.first && simp.last == dense.last, "rdpSimplify keeps endpoints")
}

// MARK: - Summary

print("=== \(passCount) passed, \(failCount) failed ===")
}

runTests()
if failCount > 0 { exit(1) }
