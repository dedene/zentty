import AppKit
import QuartzCore

#if DEBUG
struct SidebarWorklaneRowDebugSnapshot {
    let detailTexts: [String]
    let overflowText: String
    let statusText: String
    let statusTextColor: NSColor
    let statusSymbolName: String
    let topLabelColor: NSColor
    let tintLayerBackgroundColor: CGColor?
    let isWorking: Bool
    let shimmerIsAnimating: Bool
    let primaryShimmerViewIsHidden: Bool
    let primaryBaseLabelMaximumNumberOfLines: Int
    let contextPrefixText: String
    let contextPrefixRowIsVisible: Bool
    let statusShimmerIsAnimating: Bool
    let shimmerCoordinatorIdentifier: ObjectIdentifier?
    let shimmerColor: NSColor
    let statusShimmerColor: NSColor
    let statusProgressIndicatorIsVisible: Bool
    let statusProgressFraction: CGFloat
    let statusProgressToolTip: String
    let statusProgressRevealText: String
    let statusProgressRevealIsExpanded: Bool
    let statusProgressRevealLastUpdateWasAnimated: Bool
    let statusProgressRevealLastAnimationDuration: TimeInterval?
    let statusProgressColor: NSColor
    let statusProgressLastUpdateWasAnimated: Bool
    let statusTextContainerWidth: CGFloat
    let statusProgressRevealWidth: CGFloat
    let statusProgressRevealIsHidden: Bool
    let shimmerPhaseOffset: CGFloat
    let statusShimmerPhaseOffset: CGFloat
    let primaryTextColor: NSColor
    let primaryRowIndex: Int?
    let primaryTexts: [String]
    let firstPanePrimaryTextColor: NSColor?
    let firstPanePrimaryShimmerColor: NSColor?
    let firstPaneStatusShimmerColor: NSColor?
    let firstPanePrimaryHeight: CGFloat?
    let firstPaneTrailingTextColor: NSColor?
    let panePrimaryShimmerPhaseOffsets: [CGFloat]
    let primaryTrailingTexts: [String]
    let paneStatusTexts: [String]
    let paneStatusTrailingTexts: [String]
    let paneStatusSymbolNames: [String]
    let paneServerPortTexts: [[String]]
    let firstPaneServerIconIsVisible: Bool
    let paneStatusShimmerPhaseOffsets: [CGFloat]
    let firstPaneStatusTextColor: NSColor?
    let firstPaneStatusProgressIndicatorIsVisible: Bool
    let firstPaneStatusProgressFraction: CGFloat
    let firstPaneStatusProgressToolTip: String
    let firstPaneStatusProgressRevealText: String
    let firstPaneStatusProgressRevealIsExpanded: Bool
    let firstPaneStatusProgressRevealLastUpdateWasAnimated: Bool
    let firstPaneStatusProgressRevealLastAnimationDuration: TimeInterval?
    let firstPaneStatusProgressRevealLastConfigureSyncedPresentation: Bool
    let firstPaneStatusProgressColor: NSColor?
    let firstPaneStatusTextContainerWidth: CGFloat?
    let firstPaneStatusProgressRevealWidth: CGFloat?
    let firstPaneStatusProgressRevealIsHidden: Bool?
    let firstPaneStatusTrailingLabelWidth: CGFloat?
    let paneRowWidthConstraintCount: Int
    let firstPaneRowMinX: CGFloat?
    let firstPaneRowMaxTrailingInset: CGFloat?
    let firstPaneRowContentMinX: CGFloat?
    let firstPaneRowContentMaxTrailingInset: CGFloat?
    let firstPaneRowMinY: CGFloat?
    let firstPaneRowMaxTopInset: CGFloat?
    let firstPaneRowContentMinY: CGFloat?
    let firstPaneRowContentMaxTopInset: CGFloat?
    let firstPaneRowCornerRadius: CGFloat?
    let primaryTextMinX: CGFloat?
    let primaryTextMaxTrailingInset: CGFloat?
    let backgroundColor: NSColor?
    let appearanceMatch: NSAppearance.Name?
    let configureApplyCount: Int
}

enum SidebarWorklaneRowDebugInteraction {
    case setHovered(Bool)
    case statusProgressIconHover(animated: Bool)
    case statusLineHover
    case statusLineExit(pointerStillInsideLine: Bool)
    case statusLineHoverReconciliation(pointerInsideLine: Bool)
    case firstPaneStatusProgressIconHover(animated: Bool)
    case firstPaneStatusLineHover
    case firstPaneStatusLineExit(pointerStillInsideLine: Bool)
    case firstPaneStatusLineHoverReconciliation(pointerInsideLine: Bool)
    case firstPaneServerPortClick(index: Int)
}

enum SidebarWorklaneRowDebugMenuTarget {
    case firstPaneRow
}

@MainActor
struct SidebarWorklaneRowDebugAccess {
    let owner: SidebarWorklaneRowButton
    let currentSummary: WorklaneSidebarSummary?
    let currentStatusSymbolName: String
    let isWorking: Bool
    let shimmerCoordinator: SidebarShimmerCoordinator?
    let configureApplyCount: Int
    let textStack: NSStackView
    let topLabel: SidebarStaticLabel
    let primaryTextContainer: SidebarPrimaryTextContainerView
    let primaryBaseLabel: SidebarStaticLabel
    let primaryLabel: SidebarShimmerTextView
    let contextPrefixLabel: SidebarStaticLabel
    let statusBaseLabel: SidebarStaticLabel
    let statusLabel: SidebarShimmerTextView
    let statusContentStack: SidebarTaskProgressRevealLineView
    let statusProgressIndicator: SidebarTaskProgressIndicatorView
    let statusProgressRevealView: SidebarTaskProgressRevealView
    let overflowLabel: SidebarStaticLabel
    let detailLabels: [SidebarStaticLabel]
    let panePrimaryRows: [SidebarPanePrimaryRowView]
    let paneDetailLabels: [SidebarStaticLabel]
    let paneStatusRows: [SidebarPaneTextRowView]
    let paneServerRows: [SidebarPaneServerRowView]
    let paneRowButtons: [SidebarPaneRowButton]
    let paneRowContainers: [SidebarInsetContainerView]
    let tintLayer: CALayer
    let setHovered: (Bool) -> Void
    let setStatusProgressRevealVisible: (Bool, Bool) -> Void
}

@MainActor
extension SidebarWorklaneRowButton {
    var debugSnapshotForTesting: SidebarWorklaneRowDebugSnapshot {
        let access = debugAccessForTesting
        let paneRowCount = access.currentSummary?.paneRows.count ?? 0
        let detailTexts: [String]
        if access.currentSummary?.paneRows.isEmpty == false {
            detailTexts = access.paneDetailLabels
                .prefix(paneRowCount)
                .map(\.stringValue)
                .filter { $0.isEmpty == false }
        } else {
            detailTexts = access.detailLabels
                .prefix(access.currentSummary?.detailLines.count ?? 0)
                .map(\.stringValue)
        }

        let statusText: String
        let statusTextColor: NSColor
        let statusSymbolName: String
        if access.currentSummary?.paneRows.isEmpty == false {
            statusText = access.paneStatusRows.first?.text ?? ""
            statusTextColor = access.paneStatusRows.first?.textColor ?? .clear
            statusSymbolName = access.paneStatusRows.first?.symbolName ?? ""
        } else {
            statusText = access.statusBaseLabel.stringValue
            statusTextColor = access.statusBaseLabel.textColor ?? .clear
            statusSymbolName = access.currentStatusSymbolName
        }

        let primaryRowIndex: Int?
        if access.currentSummary?.paneRows.isEmpty == false {
            primaryRowIndex = access.paneRowButtons.first.flatMap {
                access.textStack.arrangedSubviews.firstIndex(of: $0)
            }
        } else {
            primaryRowIndex = access.textStack.arrangedSubviews.firstIndex {
                $0 === access.primaryTextContainer || $0.containsDescendant(access.primaryTextContainer)
            }
        }

        let primaryTextMinX: CGFloat?
        let primaryTextMaxTrailingInset: CGFloat?
        if access.currentSummary?.paneRows.isEmpty != false,
           let superview = access.primaryTextContainer.superview {
            let primaryTextFrame = access.owner.convert(access.primaryTextContainer.frame, from: superview)
            primaryTextMinX = primaryTextFrame.minX
            primaryTextMaxTrailingInset = access.owner.bounds.maxX - primaryTextFrame.maxX
        } else {
            primaryTextMinX = nil
            primaryTextMaxTrailingInset = nil
        }

        return SidebarWorklaneRowDebugSnapshot(
            detailTexts: detailTexts,
            overflowText: access.currentSummary?.overflowText ?? "",
            statusText: statusText,
            statusTextColor: statusTextColor,
            statusSymbolName: statusSymbolName,
            topLabelColor: access.topLabel.textColor ?? .clear,
            tintLayerBackgroundColor: access.tintLayer.backgroundColor,
            isWorking: access.isWorking,
            shimmerIsAnimating: access.primaryLabel.shimmerIsAnimating,
            primaryShimmerViewIsHidden: access.primaryLabel.isHidden,
            primaryBaseLabelMaximumNumberOfLines: access.primaryBaseLabel.maximumNumberOfLines,
            contextPrefixText: access.contextPrefixLabel.stringValue,
            contextPrefixRowIsVisible: access.textStack.arrangedSubviews.contains { view in
                view === access.contextPrefixLabel || view.containsDescendant(access.contextPrefixLabel)
            },
            statusShimmerIsAnimating: access.statusLabel.shimmerIsAnimating,
            shimmerCoordinatorIdentifier: access.shimmerCoordinator.map(ObjectIdentifier.init),
            shimmerColor: access.primaryLabel.shimmerColor,
            statusShimmerColor: access.statusLabel.shimmerColor,
            statusProgressIndicatorIsVisible: access.statusProgressIndicator.isHidden == false,
            statusProgressFraction: access.statusProgressIndicator.fraction,
            statusProgressToolTip: access.statusProgressIndicator.tooltipText,
            statusProgressRevealText: access.statusProgressRevealView.revealText,
            statusProgressRevealIsExpanded: access.statusProgressRevealView.isRevealed,
            statusProgressRevealLastUpdateWasAnimated: access.statusProgressRevealView.lastUpdateWasAnimated,
            statusProgressRevealLastAnimationDuration: access.statusProgressRevealView.lastAnimationDuration,
            statusProgressColor: access.statusProgressIndicator.progressColor,
            statusProgressLastUpdateWasAnimated: access.statusProgressIndicator.lastUpdateWasAnimated,
            statusTextContainerWidth: access.statusContentStack.textContainerWidthForTesting,
            statusProgressRevealWidth: access.statusContentStack.progressRevealWidthForTesting,
            statusProgressRevealIsHidden: access.statusProgressRevealView.isHidden,
            shimmerPhaseOffset: access.primaryLabel.shimmerPhaseOffsetForTesting,
            statusShimmerPhaseOffset: access.statusLabel.shimmerPhaseOffsetForTesting,
            primaryTextColor: access.primaryBaseLabel.textColor ?? .clear,
            primaryRowIndex: primaryRowIndex,
            primaryTexts: access.panePrimaryRows.prefix(paneRowCount).map(\.primaryText),
            firstPanePrimaryTextColor: access.panePrimaryRows.first?.renderedPrimaryTextColorForTesting,
            firstPanePrimaryShimmerColor: access.panePrimaryRows.first?.shimmerColorForTesting,
            firstPaneStatusShimmerColor: access.paneStatusRows.first?.shimmerColorForTesting,
            firstPanePrimaryHeight: access.panePrimaryRows.first.map { max($0.bounds.height, $0.fittingSize.height) },
            firstPaneTrailingTextColor: access.panePrimaryRows.first?.renderedTrailingTextColorForTesting,
            panePrimaryShimmerPhaseOffsets: access.panePrimaryRows.prefix(paneRowCount).map(\.shimmerPhaseOffsetForTesting),
            primaryTrailingTexts: access.panePrimaryRows.prefix(paneRowCount).compactMap(\.trailingText),
            paneStatusTexts: access.paneStatusRows.prefix(paneRowCount)
                .map(\.text)
                .filter { $0.isEmpty == false },
            paneStatusTrailingTexts: access.paneStatusRows.prefix(paneRowCount)
                .compactMap { row in row.isTrailingVisibleForTesting ? row.trailingText : nil },
            paneStatusSymbolNames: access.paneStatusRows.prefix(paneRowCount)
                .map(\.symbolName)
                .filter { $0.isEmpty == false },
            paneServerPortTexts: access.paneServerRows.prefix(paneRowCount)
                .map(\.portTextsForTesting)
                .filter { $0.isEmpty == false },
            firstPaneServerIconIsVisible: access.paneServerRows.first?.iconIsVisibleForTesting ?? false,
            paneStatusShimmerPhaseOffsets: access.paneStatusRows.prefix(paneRowCount)
                .map(\.shimmerPhaseOffsetForTesting),
            firstPaneStatusTextColor: access.paneStatusRows.first?.textColor,
            firstPaneStatusProgressIndicatorIsVisible: access.paneStatusRows.first?.progressIndicatorIsVisibleForTesting ?? false,
            firstPaneStatusProgressFraction: access.paneStatusRows.first?.progressFractionForTesting ?? 0,
            firstPaneStatusProgressToolTip: access.paneStatusRows.first?.progressToolTipForTesting ?? "",
            firstPaneStatusProgressRevealText: access.paneStatusRows.first?.progressRevealTextForTesting ?? "",
            firstPaneStatusProgressRevealIsExpanded: access.paneStatusRows.first?.progressRevealIsExpandedForTesting ?? false,
            firstPaneStatusProgressRevealLastUpdateWasAnimated: access.paneStatusRows.first?.progressRevealLastUpdateWasAnimatedForTesting ?? false,
            firstPaneStatusProgressRevealLastAnimationDuration: access.paneStatusRows.first?.progressRevealLastAnimationDurationForTesting,
            firstPaneStatusProgressRevealLastConfigureSyncedPresentation: access.paneStatusRows.first?.progressRevealLastConfigureSyncedPresentationForTesting ?? false,
            firstPaneStatusProgressColor: access.paneStatusRows.first?.progressColorForTesting,
            firstPaneStatusTextContainerWidth: access.paneStatusRows.first?.textContainerWidthForTesting,
            firstPaneStatusProgressRevealWidth: access.paneStatusRows.first?.progressRevealWidthForTesting,
            firstPaneStatusProgressRevealIsHidden: access.paneStatusRows.first?.progressRevealIsHiddenForTesting,
            firstPaneStatusTrailingLabelWidth: access.paneStatusRows.first?.trailingLabelWidthForTesting,
            paneRowWidthConstraintCount: access.paneRowContainers.filter(\.hasActiveWidthConstraintForTesting).count,
            firstPaneRowMinX: access.paneRowButtons.first.map {
                access.owner.convert($0.bounds, from: $0).minX
            },
            firstPaneRowMaxTrailingInset: access.paneRowButtons.first.map {
                access.owner.bounds.maxX - access.owner.convert($0.bounds, from: $0).maxX
            },
            firstPaneRowContentMinX: access.paneRowButtons.first?.contentMinXForTesting,
            firstPaneRowContentMaxTrailingInset: access.paneRowButtons.first?.contentMaxTrailingInsetForTesting,
            firstPaneRowMinY: access.paneRowButtons.first.map {
                access.owner.convert($0.bounds, from: $0).minY
            },
            firstPaneRowMaxTopInset: access.paneRowButtons.first.map {
                access.owner.bounds.maxY - access.owner.convert($0.bounds, from: $0).maxY
            },
            firstPaneRowContentMinY: access.paneRowButtons.first?.contentMinYForTesting,
            firstPaneRowContentMaxTopInset: access.paneRowButtons.first?.contentMaxTopInsetForTesting,
            firstPaneRowCornerRadius: access.paneRowButtons.first?.cornerRadiusForTesting,
            primaryTextMinX: primaryTextMinX,
            primaryTextMaxTrailingInset: primaryTextMaxTrailingInset,
            backgroundColor: access.owner.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
            appearanceMatch: access.owner.appearance?.bestMatch(from: [.darkAqua, .aqua]),
            configureApplyCount: access.configureApplyCount
        )
    }

    func performDebugInteractionForTesting(_ interaction: SidebarWorklaneRowDebugInteraction) {
        let access = debugAccessForTesting
        switch interaction {
        case .setHovered(let hovered):
            access.setHovered(hovered)
        case .statusProgressIconHover(let animated):
            access.setStatusProgressRevealVisible(true, animated)
        case .statusLineHover:
            access.statusContentStack.simulateMouseEnteredForTesting()
        case .statusLineExit(let pointerStillInsideLine):
            access.statusContentStack.simulateMouseExitedForTesting(pointerStillInsideLine: pointerStillInsideLine)
        case .statusLineHoverReconciliation(let pointerInsideLine):
            access.statusContentStack.simulateHoverReconciliationForTesting(pointerInsideLine: pointerInsideLine)
        case .firstPaneStatusProgressIconHover(let animated):
            access.paneStatusRows.first?.simulateProgressIconHoverForTesting(animated: animated)
        case .firstPaneStatusLineHover:
            access.paneStatusRows.first?.simulateProgressLineHoverForTesting()
        case .firstPaneStatusLineExit(let pointerStillInsideLine):
            access.paneStatusRows.first?.simulateProgressLineExitForTesting(
                pointerStillInsideLine: pointerStillInsideLine
            )
        case .firstPaneStatusLineHoverReconciliation(let pointerInsideLine):
            access.paneStatusRows.first?.simulateProgressLineHoverReconciliationForTesting(
                pointerInsideLine: pointerInsideLine
            )
        case .firstPaneServerPortClick(let index):
            guard let paneButton = access.paneRowButtons.first,
                  let serverRow = access.paneServerRows.first,
                  let pointInServerRow = serverRow.portCenterForTesting(index: index)
            else {
                return
            }

            paneButton.performPrimaryClickForTesting(at: paneButton.convert(pointInServerRow, from: serverRow))
        }
    }

    func debugMenuForTesting(
        _ target: SidebarWorklaneRowDebugMenuTarget,
        event: NSEvent
    ) -> NSMenu? {
        switch target {
        case .firstPaneRow:
            return debugAccessForTesting.paneRowButtons.first?.menu(for: event)
        }
    }
}
#endif
