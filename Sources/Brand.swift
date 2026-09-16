import SwiftUI

/// The app's one brand colour — the Zundra identity's hot pink (`#FF3D95`,
/// Pink Noise edition 02, `--z-pink`).
///
/// It is spent on exactly what the *system* accent used to carry and nothing
/// more: today's heading, the day the capture field is aimed at, a running
/// focus box. Every colour the panel already spends meaning on is deliberately
/// untouched — red `!`, blue `↑`, purple long-term, orange "Plan the day",
/// green tallies, teal agent boxes and the sixteen area hues — because those
/// say what a *row* is, while the tint only says which app you are in. A brand
/// that repaints the signals would cost the panel the thing it is for.
///
/// Written as sRGB components rather than a named asset: the app is compiled by
/// hand with `swiftc` and has no asset catalogue to put a colour in.
enum Brand {
    /// `#FF3D95`.
    static let pink = Color(.sRGB, red: 1.0, green: 0.239, blue: 0.584, opacity: 1)
}
