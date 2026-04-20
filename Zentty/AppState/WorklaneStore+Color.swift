import Foundation

extension WorklaneStore {
    @discardableResult
    func setColor(_ color: WorklaneColor?, on id: WorklaneID) -> Bool {
        guard let index = worklanes.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard worklanes[index].color != color else {
            return false
        }
        worklanes[index].color = color
        notify(.worklaneListChanged)
        return true
    }
}
