import AppKit

@MainActor
enum SidebarListRenderer {
    typealias ButtonFactory = (WorklaneSidebarSummary) -> SidebarWorklaneRowButton

    static func renderStructuralDiff(
        _ diff: SidebarRowDiff,
        summaries: [WorklaneSidebarSummary],
        currentButtons: [SidebarWorklaneRowButton],
        targetStack: NSStackView,
        theme: ZenttyTheme,
        shimmerCoordinator: SidebarShimmerCoordinator,
        reconfigureSurvivingButtons: Bool,
        buttonFactory: ButtonFactory
    ) -> [SidebarWorklaneRowButton] {
        let buttonsByID = Dictionary(
            uniqueKeysWithValues: currentButtons.compactMap { button in
                button.worklaneID.map { ($0, button) }
            }
        )
        let updatedIDs = Set(diff.updates.map(\.worklaneID))
        let summariesByID = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.worklaneID, $0) }
        )

        var insertedButtons: [WorklaneID: SidebarWorklaneRowButton] = [:]
        for insertion in diff.insertions {
            let summary = insertion.summary
            let button = buttonFactory(summary)
            button.configure(with: summary, theme: theme, animated: false)
            button.setShimmerCoordinator(shimmerCoordinator)
            button.isHidden = true
            button.alphaValue = 0
            insertedButtons[summary.worklaneID] = button
        }

        let targetButtons = summaries.compactMap { summary in
            buttonsByID[summary.worklaneID] ?? insertedButtons[summary.worklaneID]
        }
        let targetIDs = Set(targetButtons.compactMap(\.worklaneID))

        for button in currentButtons {
            targetStack.removeArrangedSubview(button)
            if let worklaneID = button.worklaneID, !targetIDs.contains(worklaneID) {
                button.removeFromSuperview()
            }
        }

        for (index, button) in targetButtons.enumerated() {
            targetStack.insertArrangedSubview(button, at: index)
            if let worklaneID = button.worklaneID, insertedButtons[worklaneID] != nil {
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: targetStack.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: targetStack.trailingAnchor),
                ])
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            for (_, button) in insertedButtons {
                button.isHidden = false
                button.animator().alphaValue = 1
            }

            for button in targetButtons {
                guard let worklaneID = button.worklaneID,
                      insertedButtons[worklaneID] == nil,
                      reconfigureSurvivingButtons || updatedIDs.contains(worklaneID),
                      let summary = summariesByID[worklaneID] else {
                    continue
                }
                button.configure(
                    with: summary,
                    theme: theme,
                    animated: true
                )
            }
        }

        return targetButtons
    }
}
