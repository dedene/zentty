import AppKit

/// Shared factory methods for the hand-rolled AppKit forms used across the Settings
/// window sections. Consolidates the row/label/separator assembly code that used to be
/// copy-pasted (with small, and sometimes accidental, per-screen drift) into every
/// `*SettingsSectionViewController`.
///
/// Visual differences between screens are intentional and preserved via parameters —
/// this type does not attempt to unify the look of Settings sections, only the code
/// that builds them.
@MainActor
enum SettingsFormBuilder {
    /// How a switch row's subtitle label should be constrained horizontally.
    enum SubtitleWidth {
        /// No explicit width constraint; the label wraps based on the stack/toggle layout.
        case unconstrained
        /// Clamp the subtitle to a fixed maximum width.
        case maxWidth(CGFloat)
        /// Pin the subtitle to the width of its containing left-hand stack, and also
        /// constrain the stack to stay clear of the toggle. Used by rows that can carry
        /// an extra accessory view below the subtitle.
        case matchStack

        fileprivate var maxWidthConstant: CGFloat? {
            if case let .maxWidth(width) = self { return width }
            return nil
        }

        fileprivate var pinsToStackWidth: Bool {
            if case .matchStack = self { return true }
            return false
        }
    }

    /// A plain wrapping label, matching the style used throughout Settings.
    static func label(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    /// A title + subtitle row with a trailing `NSSwitch`, as used by every settings
    /// section for boolean preferences.
    ///
    /// Defaults match the original `GeneralSettingsSectionViewController.makeSwitchRow`
    /// styling (14pt vertical inset, 12pt toggle spacing, 12pt subtitle font). Other
    /// screens pass explicit overrides to keep their existing look.
    static func switchRow(
        title: String,
        subtitle: String,
        toggle: NSSwitch,
        target: AnyObject,
        action: Selector,
        verticalInset: CGFloat = 14,
        toggleLeadingSpacing: CGFloat = 12,
        leftStackSpacing: CGFloat = 2,
        subtitleFontSize: CGFloat = 12,
        subtitleWidth: SubtitleWidth = .unconstrained,
        accessory: NSView? = nil
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = leftStackSpacing
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(leftStack)

        let titleLabel = label(title, font: .systemFont(ofSize: 13, weight: .semibold))
        leftStack.addArrangedSubview(titleLabel)

        let subtitleLabel = label(subtitle, font: .systemFont(ofSize: subtitleFontSize, weight: .regular))
        subtitleLabel.textColor = .secondaryLabelColor
        leftStack.addArrangedSubview(subtitleLabel)

        if let accessory {
            leftStack.addArrangedSubview(accessory)
        }

        toggle.target = target
        toggle.action = action
        toggle.controlSize = .regular
        toggle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggle)

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalInset),
            leftStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalInset),

            toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            toggle.leadingAnchor.constraint(
                greaterThanOrEqualTo: leftStack.trailingAnchor, constant: toggleLeadingSpacing),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        if let maxWidth = subtitleWidth.maxWidthConstant {
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        }

        if subtitleWidth.pinsToStackWidth {
            subtitleLabel.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true
            leftStack.trailingAnchor.constraint(
                lessThanOrEqualTo: toggle.leadingAnchor, constant: -toggleLeadingSpacing
            ).isActive = true
        }

        return container
    }

    /// A horizontal `NSBox` separator, added to `stack` and pinned to its width.
    ///
    /// Must be added to the stack before the width constraint is activated: the anchor
    /// pair needs a common ancestor at activation time, otherwise AppKit throws and
    /// aborts the caller's content assembly (leaving the pane blank).
    @discardableResult
    static func separator(addedTo stack: NSStackView) -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return separator
    }
}
