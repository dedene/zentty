import Foundation

/// Muse Code prefixes its terminal title with a braille spinner frame
/// ("⠋ zentty") for as long as it is busy — including the post-turn reminder
/// threads ("Double checking") that outlive the root `Stop` hook — and drops
/// it once the turn is over. Its hooks miss that end in two ways: a trivial
/// first turn fires no `Stop` at all, and `Stop` lands while the reminders
/// still run. The spinner settling is the turn end the user sees.
enum MuseTitleActivity {
    static func isBusy(_ title: String?) -> Bool {
        guard let title = WorklaneContextFormatter.trimmed(title),
              let spinner = title.unicodeScalars.first,
              (0x2801...0x28FF).contains(spinner.value) else {
            return false
        }
        let rest = title.unicodeScalars.dropFirst()
        guard let separator = rest.first, CharacterSet.whitespaces.contains(separator) else {
            return false
        }
        return !String(String.UnicodeScalarView(rest)).trimmingCharacters(in: .whitespaces).isEmpty
    }
}
