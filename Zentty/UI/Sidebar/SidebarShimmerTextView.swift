import AppKit
import CoreText
import QuartzCore

/// Per-row hash-derived phase offset for the shimmer animation. Offsets each
/// row's highlight slightly so multiple shimmering labels don't sweep in
/// unison. Hash-based so the same worklane / pane ID always gets the same
/// offset across renders.
enum SidebarShimmerPhaseOffset {
    fileprivate static let range: ClosedRange<CGFloat> = 0.0...0.6
    private static let seed: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    static func forIdentifier(_ identifier: String?) -> CGFloat {
        guard let identifier, identifier.isEmpty == false else {
            return 0
        }

        var hash = seed
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }

        let fraction = CGFloat(hash & 0xFFFF) / CGFloat(UInt16.max)
        return range.lowerBound + ((range.upperBound - range.lowerBound) * fraction)
    }

    static func wrapped(_ phase: CGFloat) -> CGFloat {
        let wrappedPhase = phase.truncatingRemainder(dividingBy: 1)
        return wrappedPhase >= 0 ? wrappedPhase : wrappedPhase + 1
    }
}

/// Single-line CoreText label that renders a shimmer gradient clipped to
/// glyph outlines. The shimmer sweeps across the label at a constant
/// velocity (points/sec) so long labels take longer to traverse. Multiple
/// instances share a single animation clock via `SidebarShimmerCoordinator`
/// to avoid per-label timers.
///
/// Previously lived inside `SidebarWorklaneRowButton.swift`. Extracted as
/// part of the Phase 1 row-button split. The Row button, pane row views,
/// and `SidebarView` all hold references to instances of this type.
final class SidebarShimmerTextView: NSView {
    fileprivate enum Animation {
        static let velocity: CGFloat = 130      // pts/sec — constant across all widths
        static let bandWidth: CGFloat = 48
        static let frameInterval: TimeInterval = 1.0 / 30.0
    }

    private static let textLeadingInset: CGFloat = 0

    struct LayoutSnapshot {
        let line: CTLine
        let glyphPath: CGPath
        let origin: CGPoint
        let width: CGFloat
    }

    var stringValue: String = "" {
        didSet {
            guard oldValue != stringValue else { return }
            invalidateLayout()
        }
    }

    var font: NSFont = .systemFont(ofSize: 13, weight: .semibold) {
        didSet {
            guard oldValue != font else { return }
            invalidateLayout()
        }
    }

    var lineBreakMode: NSLineBreakMode = .byTruncatingTail {
        didSet {
            guard oldValue != lineBreakMode else { return }
            invalidateLayout()
        }
    }

    var shimmerColor: NSColor = .clear {
        didSet {
            guard oldValue != shimmerColor else { return }
            needsDisplay = true
        }
    }

    var lineHeight: CGFloat = ShellMetrics.sidebarPrimaryLineHeight {
        didSet {
            guard oldValue != lineHeight else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var isShimmering: Bool = false {
        didSet {
            guard oldValue != isShimmering else { return }
            refreshSharedShimmerParticipation()
            needsDisplay = true
        }
    }

    var reducedMotion: Bool = false {
        didSet {
            guard oldValue != reducedMotion else { return }
            refreshSharedShimmerParticipation()
            needsDisplay = true
        }
    }

    var isVisibleForSharedAnimation: Bool = false {
        didSet {
            guard oldValue != isVisibleForSharedAnimation else { return }
            refreshSharedShimmerParticipation()
        }
    }

    var shimmerPhaseOffset: CGFloat = 0 {
        didSet {
            guard oldValue != shimmerPhaseOffset else { return }
            needsDisplay = true
        }
    }

    weak var shimmerCoordinator: SidebarShimmerCoordinator? {
        didSet {
            guard oldValue !== shimmerCoordinator else {
                return
            }

            oldValue?.unregister(self)
            shimmerCoordinator?.register(self)
            refreshSharedShimmerParticipation()
        }
    }

    private var sharedShimmerPhase: CGFloat = 0.5
    private var sharedShimmerInSweep = false
    private var cachedWidth: CGFloat = -1
    private var cachedStringValue = ""
    private var cachedFont: NSFont?
    private var cachedLineBreakMode: NSLineBreakMode = .byTruncatingTail
    private var cachedLayout: LayoutSnapshot?

    override var isOpaque: Bool {
        false
    }

    override var allowsVibrancy: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredTextWidth + Self.textLeadingInset, height: lineHeight)
    }

    var shimmerIsAnimating: Bool {
        canAnimateSharedShimmer && sharedShimmerInSweep
    }

    var shimmerPhaseOffsetForTesting: CGFloat {
        shimmerPhaseOffset
    }

    private var preferredTextWidth: CGFloat {
        SidebarTextMetrics.measuredWidth(for: stringValue, font: font)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.size.width
        super.setFrameSize(newSize)
        if abs(previousWidth - newSize.width) > .ulpOfOne {
            invalidateLayout()
        }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            isVisibleForSharedAnimation = false
        }
        refreshSharedShimmerParticipation()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshSharedShimmerParticipation()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard
            let context = NSGraphicsContext.current?.cgContext,
            let layout = layoutSnapshot(forWidth: bounds.width)
        else {
            return
        }

        guard canAnimateSharedShimmer, sharedShimmerInSweep else {
            return
        }

        let effectivePhase = sharedShimmerPhase + shimmerPhaseOffset
        guard effectivePhase > -0.15, effectivePhase < 1.15 else {
            return
        }

        context.saveGState()
        context.addPath(layout.glyphPath)
        context.clip()
        drawShimmerOverlay(in: context, layout: layout)
        context.restoreGState()
    }

    private func drawShimmerOverlay(
        in context: CGContext,
        layout: LayoutSnapshot
    ) {
        let availableWidth = max(0, bounds.width - Self.textLeadingInset)
        let bandWidth = Animation.bandWidth
        let originX: CGFloat
        if reducedMotion {
            originX = Self.textLeadingInset + (availableWidth / 2) - (bandWidth / 2)
        } else {
            let travel = availableWidth + bandWidth
            let phase = sharedShimmerPhase + shimmerPhaseOffset
            originX = Self.textLeadingInset - bandWidth + (travel * phase)
        }

        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    shimmerColor.withAlphaComponent(0).cgColor,
                    shimmerColor.cgColor,
                    shimmerColor.withAlphaComponent(0).cgColor,
                ] as CFArray,
                locations: [0, 0.5, 1]
            )
        else {
            return
        }

        let start = CGPoint(x: originX, y: layout.origin.y)
        let end = CGPoint(x: originX + bandWidth, y: layout.origin.y)
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
    }

    private func layoutSnapshot(forWidth width: CGFloat) -> LayoutSnapshot? {
        let availableWidth = width - Self.textLeadingInset
        guard availableWidth > 0, stringValue.isEmpty == false else {
            return nil
        }

        if let cachedLayout,
            abs(cachedWidth - width) <= .ulpOfOne,
            cachedStringValue == stringValue,
            cachedFont == font,
            cachedLineBreakMode == lineBreakMode
        {
            return cachedLayout
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: stringValue, attributes: attributes)
        )
        let drawLine = truncatedLine(
            from: line, attributes: attributes, availableWidth: availableWidth)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(drawLine, &ascent, &descent, nil))
        let totalLineHeight = ascent + descent
        let bottomPadding = max(0, (bounds.height - totalLineHeight) / 2)
        let origin = CGPoint(x: Self.textLeadingInset, y: bottomPadding + descent)
        let glyphPath = glyphPath(for: drawLine, lineOrigin: origin)
        let snapshot = LayoutSnapshot(
            line: drawLine,
            glyphPath: glyphPath,
            origin: origin,
            width: lineWidth
        )

        cachedWidth = width
        cachedStringValue = stringValue
        cachedFont = font
        cachedLineBreakMode = lineBreakMode
        cachedLayout = snapshot

        return snapshot
    }

    private func truncatedLine(
        from line: CTLine,
        attributes: [NSAttributedString.Key: Any],
        availableWidth: CGFloat
    ) -> CTLine {
        guard lineBreakMode == .byTruncatingTail else {
            return line
        }

        guard CTLineGetTypographicBounds(line, nil, nil, nil) > availableWidth else {
            return line
        }

        let token = NSAttributedString(string: "\u{2026}", attributes: attributes)
        let tokenLine = CTLineCreateWithAttributedString(token)
        return CTLineCreateTruncatedLine(line, Double(availableWidth), .end, tokenLine) ?? line
    }

    private func glyphPath(
        for line: CTLine,
        lineOrigin: CGPoint
    ) -> CGPath {
        let glyphPath = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as NSArray

        for case let run as CTRun in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else {
                continue
            }

            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let fontObject = attributes[kCTFontAttributeName] else {
                continue
            }
            let ctFont = fontObject as! CTFont

            var glyphs = Array(repeating: CGGlyph(), count: glyphCount)
            var positions = Array(repeating: CGPoint.zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)

            for index in 0..<glyphCount {
                guard let path = CTFontCreatePathForGlyph(ctFont, glyphs[index], nil) else {
                    continue
                }

                let transform = CGAffineTransform(
                    translationX: lineOrigin.x + positions[index].x,
                    y: lineOrigin.y + positions[index].y
                )
                glyphPath.addPath(path, transform: transform)
            }
        }

        return glyphPath
    }

    func applySharedShimmerState(phase: CGFloat, inSweep: Bool) {
        sharedShimmerPhase = phase
        sharedShimmerInSweep = inSweep
        needsDisplay = true
    }

    func resetSharedShimmerState() {
        sharedShimmerPhase = 0.5
        sharedShimmerInSweep = false
        needsDisplay = true
    }

    fileprivate var canAnimateSharedShimmer: Bool {
        isShimmering && isVisibleForSharedAnimation && reducedMotion == false
    }

    private func refreshSharedShimmerParticipation() {
        guard let shimmerCoordinator else {
            resetSharedShimmerState()
            return
        }

        shimmerCoordinator.labelStateDidChange()
        if canAnimateSharedShimmer {
            needsDisplay = true
        } else {
            resetSharedShimmerState()
        }
    }

    private func invalidateLayout() {
        cachedWidth = -1
        cachedStringValue = ""
        cachedFont = nil
        cachedLineBreakMode = lineBreakMode
        cachedLayout = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}

/// Shared animation clock for all `SidebarShimmerTextView` instances.
/// Runs a single Timer on the main run loop, sweeps a phase from
/// `sweepStartPhase` to 1.0 over the longest active label's width /
/// velocity, then pauses for a random interval before the next sweep.
/// Per-label hash-derived offsets stagger band visibility so multiple
/// labels don't shimmer in lockstep.
@MainActor
final class SidebarShimmerCoordinator {
    private static let pauseRange: ClosedRange<CFTimeInterval> = 2.5...4.0

    private var labels: NSHashTable<SidebarShimmerTextView> = .weakObjects()
    private var timer: Timer?
    private var windowIsRenderable = false
    private var currentPhase: CGFloat = 0.5
    private var inSweep = false
    private var cycleStart: CFTimeInterval = 0
    private var pauseDuration: CFTimeInterval = 0

    var isRunningForTesting: Bool {
        timer != nil
    }

    static var pauseRangeForTesting: ClosedRange<CFTimeInterval> {
        pauseRange
    }

    fileprivate func register(_ label: SidebarShimmerTextView) {
        labels.add(label)
        label.applySharedShimmerState(phase: currentPhase, inSweep: inSweep)
        refreshAnimationState()
    }

    fileprivate func unregister(_ label: SidebarShimmerTextView) {
        labels.remove(label)
        refreshAnimationState()
    }

    func setWindowIsRenderable(_ isRenderable: Bool) {
        guard windowIsRenderable != isRenderable else {
            return
        }

        windowIsRenderable = isRenderable
        refreshAnimationState()
    }

    func labelStateDidChange() {
        refreshAnimationState()
    }

    private var activeLabels: [SidebarShimmerTextView] {
        labels.allObjects.filter { $0.canAnimateSharedShimmer }
    }

    private func refreshAnimationState() {
        let labels = activeLabels
        guard windowIsRenderable, labels.isEmpty == false else {
            suspendTimer()
            labelsForDisplay().forEach { $0.resetSharedShimmerState() }
            return
        }

        if timer == nil {
            resumeOrStartTimer()
        }

        applyCurrentState(to: labels)
    }

    private func labelsForDisplay() -> [SidebarShimmerTextView] {
        labels.allObjects
    }

    private var suspendedElapsed: CFTimeInterval?

    private static let sweepStartPhase = -SidebarShimmerPhaseOffset.range.upperBound
    private static let sweepPhaseRange: CGFloat = 1.0 - sweepStartPhase

    private func resumeOrStartTimer() {
        if let elapsed = suspendedElapsed {
            suspendedElapsed = nil
            cycleStart = CACurrentMediaTime() - elapsed
        } else {
            cycleStart = CACurrentMediaTime()
            pauseDuration = .random(in: Self.pauseRange)
            inSweep = true
            currentPhase = Self.sweepStartPhase
        }

        let timer = Timer(
            timeInterval: SidebarShimmerTextView.Animation.frameInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func suspendTimer() {
        if timer != nil {
            suspendedElapsed = CACurrentMediaTime() - cycleStart
        }
        timer?.invalidate()
        timer = nil
    }

    private func stopTimer() {
        suspendedElapsed = nil
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard windowIsRenderable else {
            stopTimer()
            inSweep = false
            currentPhase = 0.5
            labelsForDisplay().forEach { $0.resetSharedShimmerState() }
            return
        }

        let labels = activeLabels
        guard labels.isEmpty == false else {
            suspendTimer()
            labelsForDisplay().forEach { $0.resetSharedShimmerState() }
            return
        }

        let travelDistance = max(1, labels.map(\.bounds.width).max() ?? 1) + SidebarShimmerTextView.Animation.bandWidth
        let singleCrossDuration = CFTimeInterval(travelDistance / SidebarShimmerTextView.Animation.velocity)
        let sweepDuration = singleCrossDuration * CFTimeInterval(Self.sweepPhaseRange)
        let cycleDuration = sweepDuration + pauseDuration
        let elapsed = CACurrentMediaTime() - cycleStart

        if elapsed >= cycleDuration {
            cycleStart = CACurrentMediaTime()
            pauseDuration = .random(in: Self.pauseRange)
            currentPhase = Self.sweepStartPhase
            inSweep = true
        } else if elapsed < sweepDuration {
            currentPhase = Self.sweepStartPhase + CGFloat(elapsed / sweepDuration) * Self.sweepPhaseRange
            inSweep = true
        } else {
            inSweep = false
        }

        applyCurrentState(to: labels)
    }

    private func applyCurrentState(to labels: [SidebarShimmerTextView]) {
        labels.forEach { $0.applySharedShimmerState(phase: currentPhase, inSweep: inSweep) }
    }
}
