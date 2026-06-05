import Foundation

extension WorklaneStore {
    /// Sets or clears the optional user-visible worklane title. The value is
    /// trimmed; empty or whitespace-only input clears the title (nil).
    @discardableResult
    func setTitle(_ title: String?, on id: WorklaneID) -> Bool {
        guard let index = worklanes.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let resolved = WorklaneContextFormatter.trimmed(title)
        guard worklanes[index].title != resolved else {
            return false
        }
        worklanes[index].title = resolved
        notify(.worklaneListChanged)
        return true
    }
}
