import Foundation

/// How the task list is ordered. Two dimensions (creation time, last run time),
/// each ascending or descending, plus the user's own drag order.
public enum TaskSortOption: String, CaseIterable, Sendable {
    case createdDesc
    case createdAsc
    case lastRunDesc
    case lastRunAsc
    /// The user's drag order (`ScheduledTask.sortOrder`), issue #56.
    case custom

    /// The date this option sorts by, for a given task. Last-run options fall
    /// back to creation time for tasks that have never run.
    private func sortKey(for task: ScheduledTask) -> Date {
        switch self {
        case .createdDesc, .createdAsc, .custom: return task.createdAt
        case .lastRunDesc, .lastRunAsc: return task.lastRunAt ?? task.createdAt
        }
    }

    private var isAscending: Bool {
        switch self {
        case .createdAsc, .lastRunAsc: return true
        case .createdDesc, .lastRunDesc, .custom: return false
        }
    }

    /// Sort the given tasks according to this option.
    ///
    /// Enabled state outranks the time key: a disabled task can't fire on its
    /// own, so it sinks below the live ones (within whatever section the list
    /// puts it in) instead of interleaving with them by timestamp. `.custom`
    /// is the exception — the user placed every row, disabled ones included.
    public func sort(_ tasks: [ScheduledTask]) -> [ScheduledTask] {
        if self == .custom {
            return tasks.sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        return tasks.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
            let lk = sortKey(for: lhs), rk = sortKey(for: rhs)
            return isAscending ? lk < rk : lk > rk
        }
    }

    /// Applies a drag made in a possibly filtered list to the whole section.
    ///
    /// `section` is every task of the section in its current custom order;
    /// `visible` is the subset on screen (same relative order), which is what
    /// `source` / `destination` index into, with `onMove` semantics. Moved
    /// rows land just before the first unmoved visible row at or after
    /// `destination` — or right after the last unmoved visible row when
    /// dropped at the end — so rows hidden by a filter or search keep their
    /// place relative to their visible neighbours.
    public static func move(
        _ section: [ScheduledTask],
        visible: [ScheduledTask],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [ScheduledTask] {
        let moving = source.filter { visible.indices.contains($0) }.map { visible[$0] }
        guard !moving.isEmpty else { return section }
        let movingIDs = Set(moving.map(\.id))
        var remaining = section.filter { !movingIDs.contains($0.id) }
        let staying = visible.filter { !movingIDs.contains($0.id) }
        guard !staying.isEmpty else { return section }

        let start = min(max(destination, 0), visible.count)
        let insertAt: Int
        if let anchor = visible[start...].first(where: { !movingIDs.contains($0.id) }),
           let index = remaining.firstIndex(where: { $0.id == anchor.id }) {
            insertAt = index
        } else if let last = staying.last,
                  let index = remaining.firstIndex(where: { $0.id == last.id }) {
            insertAt = index + 1
        } else {
            return section
        }
        remaining.insert(contentsOf: moving, at: insertAt)
        return remaining
    }
}
