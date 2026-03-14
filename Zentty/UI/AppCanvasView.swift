import AppKit

final class AppCanvasView: NSView {
    private let sidebarView = SidebarView()
    private let contextStripView = ContextStripView()
    private let paneStripView = PaneStripView()

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
        layer?.cornerRadius = 26
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.76).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.10).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 32
        layer?.shadowOffset = CGSize(width: 0, height: 18)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        contextStripView.translatesAutoresizingMaskIntoConstraints = false
        paneStripView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(sidebarView)
        contentView.addSubview(contextStripView)
        contentView.addSubview(paneStripView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),

            sidebarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: 92),

            contextStripView.topAnchor.constraint(equalTo: contentView.topAnchor),
            contextStripView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            contextStripView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contextStripView.heightAnchor.constraint(equalToConstant: 52),

            paneStripView.topAnchor.constraint(equalTo: contextStripView.bottomAnchor),
            paneStripView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            paneStripView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            paneStripView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    func render(_ state: PaneStripState) {
        contextStripView.render(state)
        paneStripView.render(state)
    }
}
