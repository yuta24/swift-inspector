import Foundation
import SwiftUI

/// Centralised access to the small set of `UserDefaults` knobs the user can
/// tweak in Settings. Wraps `@AppStorage` keys so SwiftUI views and the model
/// reach for the same string in one place — keeps drift between the writer
/// (PreferencesView) and reader (AppInspectorModel) impossible.
enum UserPreferences {
    enum Keys {
        static let screenshotJPEGQuality = "screenshotJPEGQuality"
        /// Last Figma frame URL the user typed in the inspector's compare
        /// section. Persisted across launches as a convenience — designers
        /// usually compare against the same screen multiple times in a row,
        /// so we pre-fill the field rather than ask them to re-paste.
        static let figmaLastFrameURL = "figmaLastFrameURL"
    }

    /// JPEG compression quality the macOS client asks the device to use for
    /// group screenshots. Server clamps to [0.1, 1.0]; default 0.7.
    static var screenshotJPEGQuality: Double {
        let stored = UserDefaults.standard.double(forKey: Keys.screenshotJPEGQuality)
        // `double(forKey:)` returns 0 when the key is unset — treat that as
        // "user hasn't picked one yet" rather than as a literal 0.
        return stored == 0 ? 0.7 : stored
    }
}
