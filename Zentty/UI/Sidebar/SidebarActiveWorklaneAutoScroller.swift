import Foundation

@MainActor
final class SidebarActiveWorklaneAutoScroller {
    typealias DeferredScheduler = (@escaping () -> Void) -> Void

    private let deferExecution: DeferredScheduler
    private var requestGeneration = 0

    init(deferExecution: @escaping DeferredScheduler = SidebarActiveWorklaneAutoScroller.mainAsync) {
        self.deferExecution = deferExecution
    }

    func scrollToActiveWorklaneIfNeeded(
        _ worklaneID: WorklaneID,
        currentActiveID: @escaping () -> WorklaneID?,
        layoutIfNeeded: @escaping () -> Void,
        isVisible: @escaping (WorklaneID) -> Bool,
        scroll: @escaping (WorklaneID) -> Void
    ) {
        requestGeneration &+= 1
        let generation = requestGeneration

        deferExecution { [weak self, deferExecution] in
            guard let self,
                  self.requestGeneration == generation,
                  currentActiveID() == worklaneID else {
                return
            }

            layoutIfNeeded()
            deferExecution { [weak self] in
                guard let self,
                      self.requestGeneration == generation,
                      currentActiveID() == worklaneID else {
                    return
                }

                layoutIfNeeded()
                if !isVisible(worklaneID) {
                    scroll(worklaneID)
                }
            }
        }
    }

    nonisolated private static func mainAsync(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }
}
