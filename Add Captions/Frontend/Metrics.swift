import SwiftUI

/// The spacing steps and corner radius every screen uses (the same steps as Lecture Me Faster), so
/// screens agree with each other.
enum Metrics {
    static let tight: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let regular: CGFloat = 16
    static let large: CGFloat = 24
    static let extraLarge: CGFloat = 40

    static let cornerRadius: CGFloat = 8
    /// The width of the caption list beside the video on wide screens.
    static let captionListWidth: CGFloat = 380
}

// `Color.brand` (#2774AE, as in Lecture Me Faster), `Color.canvas` and `Color.panel` come from the asset
// catalogue; `MyApp` sets the brand colour as the tint.

extension View {
    /// The whole window's background, including behind the toolbar.
    @ViewBuilder func windowCanvas() -> some View {
        #if os(macOS)
        containerBackground(Color.canvas, for: .window)
        #else
        background(Color.canvas)
        #endif
    }
}

/// "1:05" or "1:02:05" (with tenths when `precise`), for caption times.
nonisolated func formatTime(_ seconds: Double, precise: Bool = false) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    let whole = Int(safe)
    let hours = whole / 3600, minutes = whole / 60 % 60, secs = whole % 60
    var text = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    if precise { text += String(format: ".%d", Int((safe - Double(whole)) * 10)) }
    return text
}
