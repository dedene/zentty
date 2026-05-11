import AppKit

@MainActor
enum MoveToWorklaneMenuBuilder {
    static func makeSubmenu(
        catalog: WorklaneDestinationCatalog,
        paneID: PaneID
    ) -> NSMenu {
        let submenu = NSMenu(title: "")
        submenu.autoenablesItems = false

        for (groupIndex, group) in catalog.groups.enumerated() {
            for summary in group.summaries {
                submenu.addItem(makeDestinationItem(summary: summary, paneID: paneID))
            }
            if groupIndex < catalog.groups.count - 1 {
                submenu.addItem(.separator())
            }
        }

        if catalog.canCreateNewWorklane {
            if !catalog.groups.isEmpty {
                submenu.addItem(.separator())
            }
            submenu.addItem(makeNewWorklaneItem(paneID: paneID))
        }

        return submenu
    }

    static func makeDestinationItem(
        summary: WorklaneDestinationSummary,
        paneID: PaneID
    ) -> NSMenuItem {
        let title = summary.additionalPaneCount > 0
            ? "\(summary.primaryPaneTitle)  +\(summary.additionalPaneCount) more"
            : summary.primaryPaneTitle
        let item = NSMenuItem(
            title: title,
            action: #selector(MainWindowController.movePaneToWorklane(_:)),
            keyEquivalent: ""
        )
        item.image = worklaneColorDotImage(for: summary.color)
        item.representedObject = MovePaneToWorklaneRequest(
            sourcePaneID: paneID,
            destinationWindowID: summary.windowID,
            destinationWorklaneID: summary.worklaneID
        )
        return item
    }

    static func makeNewWorklaneItem(paneID: PaneID) -> NSMenuItem {
        let item = NSMenuItem(
            title: "New Worklane in This Window",
            action: #selector(MainWindowController.movePaneToNewWorklaneInThisWindow(_:)),
            keyEquivalent: ""
        )
        item.image = NSImage(systemSymbolName: "rectangle.stack.badge.plus",
                             accessibilityDescription: "New Worklane")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        item.representedObject = paneID
        return item
    }

    static func worklaneColorDotImage(for color: WorklaneColor?) -> NSImage {
        let fill: NSColor = color?.tint(alpha: 1.0) ?? NSColor.tertiaryLabelColor
        let diameter: CGFloat = 10
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
