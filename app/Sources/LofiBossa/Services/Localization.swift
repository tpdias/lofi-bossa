import Foundation

/// A string from the app's String Catalog for places that need a `String`, not a `Text`:
/// ternaries (`on ? L("On") : L("Off")`), `.help`, accessibility values, alert bodies.
/// Literals are extracted into `Localizable.xcstrings` like any `String(localized:)`.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value)
}

/// Instrument and other catalog names that are stored as English identifiers in project files
/// but shown in the reader's language.
func localizedName(_ name: String) -> String {
    String(localized: String.LocalizationValue(name))
}
