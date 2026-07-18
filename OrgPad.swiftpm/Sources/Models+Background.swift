import Foundation

// MARK: - Optional server-suggested background
//
// The v2 protocol may (optionally) let the server suggest an export background
// per session — e.g. an org file configured for dark-mode figures. This is a
// PURELY ADDITIVE, OPTIONAL field on the session JSON:
//
//     {"session_id":…, "mode":…, "name":…, "drawing":…,
//      "background": "transparent" | "dark" | "light"}   // optional
//
// If absent (the common case, and the current v1 wire shape), the app defaults
// to `.transparent`. This keeps the app forward-compatible without requiring
// the elisp side to send anything new.
//
// NOTE: `Session` (in Models.swift) currently declares explicit CodingKeys and
// a manual set of fields. To read `background` we cannot just add a stored
// property here (extensions can't add stored properties). The integrator has
// two equivalent options; pick ONE:
//
//   (A) Add `let backgroundRaw: String?` to `Session` with
//       CodingKeys `case backgroundRaw = "background"`, and delete the
//       stub below. Preferred — single source of truth.
//
//   (B) Keep Session untouched and decode lazily. Not possible cleanly without
//       the raw JSON, so (A) is recommended.
//
// Until the integrator wires (A), the computed property below returns nil so
// the app compiles and defaults to transparent. It is written so that when
// `Session` gains a `backgroundRaw: String?` field, you only delete the
// `return nil` stub and uncomment the mapping.

extension Session {
    /// Server-suggested export/surface background, or nil (=> app default).
    var suggestedBackground: CanvasBackground? {
        // Session now carries `backgroundRaw` (the JSON "background" field).
        // The wire words transparent/dark/light map to the CanvasBackground
        // rawValues; a custom colour string returns nil -> app default transparent.
        guard let raw = backgroundRaw else { return nil }
        return CanvasBackground(rawValue: raw)
    }
}
