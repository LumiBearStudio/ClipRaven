import Foundation

/// Recovers a "probably-mistyped" query when the user had the wrong
/// keyboard layout active. Used by the search pipeline as a last-resort
/// fallback: if a search returns zero results we ask every registered
/// recoverer whether the query could be the user's intended words typed
/// under the wrong input mode.
///
/// Example: on a US QWERTY keyboard with Korean 두벌식 IME off, typing
/// the keys `z k x l a h` produces the literal string "zkxlah" rather
/// than "카카오". A `KoreanLayoutRecoverer` translates "zkxlah" back to
/// "카카오" so the search can be re-run with the corrected query.
///
/// Each concrete recoverer covers one script that has a conventional
/// keyboard layout swap with Latin (Korean / Russian / Greek / Thai).
/// Languages whose input uses an IME over romaji (Japanese, Chinese) are
/// out of scope — the issue there isn't keyboard layout but IME state.
protocol KeyboardLayoutRecoverer {
    /// Short identifier used in UI copy (e.g. `"ko"` shown inside an
    /// accessibility label) and for grouping suggestions.
    var language: String { get }

    /// User pressed Latin keys while their intended output was this
    /// language's native script. Returns the decoded native-script string,
    /// or nil if the input cannot plausibly be a mistyped version.
    func decodeLatinToNative(_ text: String) -> String?

    /// User had the native-script IME active while they wanted to type
    /// Latin letters. Returns the intended Latin string, or nil.
    func decodeNativeToLatin(_ text: String) -> String?
}

/// Registry of every active recoverer. Kept as a simple array rather
/// than a protocol-witness table so adding a new language in a future
/// release means appending one line here — no `DynamicLibrary` / MCP /
/// plugin infrastructure to maintain.
///
/// Iteration order is the trial order: if two recoverers both return a
/// viable decoding, the earlier one wins. Korean is first because it's
/// ClipRaven's primary audience.
enum LayoutRecoveryRegistry {
    static let recoverers: [any KeyboardLayoutRecoverer] = [
        KoreanLayoutRecoverer(),
        // v1.2+: RussianLayoutRecoverer(), GreekLayoutRecoverer(), ThaiLayoutRecoverer()
    ]
}
