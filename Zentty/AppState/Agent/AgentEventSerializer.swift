import Foundation

/// Serializes agent hook events per pane.
///
/// IPC connections run on independent threads, so sibling hooks from one agent
/// race: an adapter's read-decide-write against its session store, and the
/// order its payloads are posted in. Running each adapter pass and its posts
/// on the pane's serial stripe makes them one critical section.
///
/// Panes are striped over a fixed set of queues, so there is no per-pane queue
/// lifecycle. Panes that land on the same stripe wait for each other, and
/// events without a pane ID all share one stripe.
final class AgentEventSerializer: Sendable {
    static let shared = AgentEventSerializer()
    private static let stripeCount = 16

    private let stripes: [DispatchQueue] = (0..<stripeCount).map { index in
        DispatchQueue(label: "be.zenjoy.zentty.agent-events.\(index)")
    }

    func stripeIndex(forPaneID paneID: String?) -> Int {
        guard let paneID else { return 0 }
        return Int(UInt(bitPattern: paneID.hashValue) % UInt(Self.stripeCount))
    }

    func run<Result>(paneID: String?, body: () throws -> Result) rethrows -> Result {
        try stripes[stripeIndex(forPaneID: paneID)].sync(execute: body)
    }
}
