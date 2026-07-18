// Verifies ExportGeometry.exportRect — the pure CGRect math from CanvasScreen.
// Run: swift verify_export.swift
import Foundation
import CoreGraphics

enum ExportGeometry {
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
func check(_ cond: Bool, _ msg: String) {
    if !cond { fatalError("FAIL: \(msg)") }
    print("PASS: \(msg)")
}
check(ExportGeometry.exportRect(drawingBounds: .null) == CGRect(x: 0, y: 0, width: 200, height: 150),
      "null bounds -> 200x150 at origin")
check(ExportGeometry.exportRect(drawingBounds: .zero) == CGRect(x: 0, y: 0, width: 200, height: 150),
      "zero bounds -> 200x150 at origin")
let bigOut = ExportGeometry.exportRect(drawingBounds: CGRect(x: 100, y: 100, width: 400, height: 300))
check(bigOut == CGRect(x: 80, y: 80, width: 440, height: 340), "large expands 20pt each side")
let smallOut = ExportGeometry.exportRect(drawingBounds: CGRect(x: 0, y: 0, width: 10, height: 10))
check(smallOut.width == 200 && smallOut.height == 150, "small -> min size 200x150")
check(abs(smallOut.midX - 5) < 0.001 && abs(smallOut.midY - 5) < 0.001, "small stays centered")
let wideOut = ExportGeometry.exportRect(drawingBounds: CGRect(x: 0, y: 0, width: 400, height: 10))
check(wideOut.width == 440 && wideOut.height == 150, "wide-short: width kept, height bumped")
let exactOut = ExportGeometry.exportRect(drawingBounds: CGRect(x: 0, y: 0, width: 160, height: 110))
check(exactOut == CGRect(x: -20, y: -20, width: 200, height: 150), "exactly-min after inset stays")
print("ALL EXPORT GEOMETRY CHECKS PASSED")
