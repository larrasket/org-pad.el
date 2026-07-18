import SwiftUI

/// Compose a `Glass` value from optional tint + interactivity. Kept as a free
/// function (not a @ViewBuilder-adjacent method) so control flow isn't parsed
/// as view expressions.
@available(iOS 26.0, *)
func orgPadMakeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

// MARK: - GlassKit: availability-gated Liquid Glass helpers (iOS 26) with an
// iPadOS 16 fallback path (.regularMaterial / .ultraThinMaterial).
//
// Rationale: the app targets iPadOS 16+. The iOS 26 Liquid Glass APIs
// (`glassEffect(_:in:)`, `GlassEffectContainer`, `.buttonStyle(.glass)` /
// `.glassProminent`, `glassEffectID`) only exist at runtime on iPadOS 26+.
// Every glass touch-point in the app funnels through these helpers so there is
// exactly one place doing the `#available` dance and one place defining the
// fallback look. This keeps CanvasScreen / ConnectScreen / WaitingScreen clean.
//
// NOTE ON COMPILING BELOW iOS 26 SDK: these helpers *reference* iOS-26-only
// symbols (Glass, GlassEffectContainer, .glass button style). They therefore
// require building against the iOS 26 SDK (Xcode 26 / Swift Playgrounds on
// iPadOS 26). Because the whole file is written against iOS 26 symbols but
// guarded at runtime with `#available`, it still *runs* on iPadOS 16 devices —
// the `else` branches execute there. The min *deployment* target stays 16; the
// min *SDK* is 26. This is the standard adopt-new-API pattern.

// MARK: Glass background for arbitrary containers (toolbars, cards, panels)

extension View {
    /// Apply a Liquid Glass background in the given shape on iOS 26+, falling
    /// back to `.regularMaterial` clipped to the same shape on earlier systems.
    /// `tint` optionally colors the glass (e.g. a subtle accent on the toolbar);
    /// `interactive` makes it react to touch (use for tappable glass surfaces).
    @ViewBuilder
    func orgPadGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            // Build the Glass value OUTSIDE the ViewBuilder: statements like
            // `if let tint { … }` inside a @ViewBuilder body are parsed as view
            // expressions, not control flow, which fails to typecheck.
            self.glassEffect(orgPadMakeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(shape.fill(.regularMaterial))
        }
    }

    /// Convenience: capsule-shaped glass (the default Liquid Glass shape).
    @ViewBuilder
    func orgPadGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        self.orgPadGlass(in: Capsule(), tint: tint, interactive: interactive)
    }
}

// MARK: Glass container that morphs its children on iOS 26

/// A container that provides the shared sampling region Liquid Glass needs to
/// blend/morph overlapping glass shapes. On pre-26 systems it is a transparent
/// pass-through so the same view tree compiles and lays out identically.
struct OrgPadGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: Button styles

extension View {
    /// Secondary/utility glass button (undo, redo, tool toggles).
    @ViewBuilder
    func orgPadGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Primary action button (Done). Opaque, high-emphasis glass.
    @ViewBuilder
    func orgPadGlassProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
