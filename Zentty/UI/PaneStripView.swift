import AppKit

final class PaneStripView: NSView {
    private let motionController = PaneStripMotionController()
    private let stack = NSStackView()
    private var orderedPaneIDs: [PaneID] = []
    private var paneViews: [PaneID: PaneContainerView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -18),
        ])
    }

    func render(_ state: PaneStripState) {
        let nextPaneIDs = state.layoutItems.map(\.pane.id)

        guard orderedPaneIDs == nextPaneIDs else {
            rebuildStack(with: state)
            orderedPaneIDs = nextPaneIDs
            return
        }

        motionController.animate(in: self) {
            self.applyState(state)
        }
    }

    private func subtitle(for index: Int, focusedIndex: Int) -> String {
        if index == focusedIndex {
            return "focused"
        }

        if index < focusedIndex {
            return index == focusedIndex - 1 ? "left" : "off-left"
        }

        return index == focusedIndex + 1 ? "right" : "off-right"
    }

    private func rebuildStack(with state: PaneStripState) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        paneViews.removeAll()

        state.layoutItems.enumerated().forEach { index, item in
            let paneView = PaneContainerView(
                title: item.pane.title,
                subtitle: subtitle(for: index, focusedIndex: state.focusedIndex),
                emphasized: item.isFocused
            )
            paneViews[item.pane.id] = paneView
            stack.addArrangedSubview(paneView)
        }
    }

    private func applyState(_ state: PaneStripState) {
        state.layoutItems.enumerated().forEach { index, item in
            paneViews[item.pane.id]?.render(
                title: item.pane.title,
                subtitle: subtitle(for: index, focusedIndex: state.focusedIndex),
                width: item.width,
                isFocused: item.isFocused
            )
        }
    }
}
