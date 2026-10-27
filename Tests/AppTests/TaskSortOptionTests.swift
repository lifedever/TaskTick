import Testing
import Foundation
import TaskTickCore
@testable import TaskTickApp

@Suite("TaskSortOption Tests")
struct TaskSortOptionTests {

    private func task(_ name: String, created: TimeInterval, lastRun: TimeInterval?) -> ScheduledTask {
        let t = ScheduledTask(name: name)
        t.createdAt = Date(timeIntervalSince1970: created)
        t.lastRunAt = lastRun.map { Date(timeIntervalSince1970: $0) }
        return t
    }

    @Test("createdDesc orders newest-created first")
    func createdDesc() {
        let a = task("a", created: 100, lastRun: nil)
        let b = task("b", created: 200, lastRun: nil)
        #expect(TaskSortOption.createdDesc.sort([a, b]).map(\.name) == ["b", "a"])
    }

    @Test("createdAsc orders oldest-created first")
    func createdAsc() {
        let a = task("a", created: 100, lastRun: nil)
        let b = task("b", created: 200, lastRun: nil)
        #expect(TaskSortOption.createdAsc.sort([b, a]).map(\.name) == ["a", "b"])
    }

    @Test("lastRunDesc orders most-recently-run first, falling back to createdAt")
    func lastRunDesc() {
        let a = task("a", created: 100, lastRun: 500) // ran at 500
        let b = task("b", created: 300, lastRun: nil) // never ran → createdAt 300
        #expect(TaskSortOption.lastRunDesc.sort([b, a]).map(\.name) == ["a", "b"])
    }

    @Test("lastRunAsc orders least-recently-run first")
    func lastRunAsc() {
        let a = task("a", created: 100, lastRun: 500)
        let b = task("b", created: 300, lastRun: nil)
        #expect(TaskSortOption.lastRunAsc.sort([a, b]).map(\.name) == ["b", "a"])
    }

    @Test("disabled tasks sink below enabled ones, whatever the time ordering")
    func disabledSinks() {
        let enabled = task("enabled", created: 100, lastRun: nil)   // oldest
        let disabled = task("disabled", created: 900, lastRun: nil) // newest
        disabled.isEnabled = false
        // createdDesc would normally put the newer "disabled" first.
        #expect(TaskSortOption.createdDesc.sort([disabled, enabled]).map(\.name) == ["enabled", "disabled"])
        // ...and createdAsc would normally put the older "enabled" first anyway,
        // so check the option that would otherwise disagree too.
        #expect(TaskSortOption.createdAsc.sort([disabled, enabled]).map(\.name) == ["enabled", "disabled"])
    }

    @Test("disabled tasks keep the time ordering among themselves")
    func disabledOrderedInternally() {
        let old = task("old", created: 100, lastRun: nil)
        let new = task("new", created: 900, lastRun: nil)
        old.isEnabled = false
        new.isEnabled = false
        #expect(TaskSortOption.createdDesc.sort([old, new]).map(\.name) == ["new", "old"])
        #expect(TaskSortOption.createdAsc.sort([new, old]).map(\.name) == ["old", "new"])
    }

    // MARK: - Custom order (issue #56)

    private func ordered(_ names: [String]) -> [ScheduledTask] {
        names.enumerated().map { index, name in
            let t = task(name, created: TimeInterval(index), lastRun: nil)
            t.sortOrder = index
            return t
        }
    }

    @Test("custom orders by sortOrder and ignores last-run time")
    func customUsesSortOrder() {
        let a = task("a", created: 100, lastRun: 900)
        let b = task("b", created: 200, lastRun: nil)
        a.sortOrder = 1
        b.sortOrder = 0
        #expect(TaskSortOption.custom.sort([a, b]).map(\.name) == ["b", "a"])
    }

    @Test("custom keeps a disabled task where the user put it")
    func customDoesNotSinkDisabled() {
        let a = task("a", created: 100, lastRun: nil)
        let b = task("b", created: 200, lastRun: nil)
        a.sortOrder = 0
        a.isEnabled = false
        b.sortOrder = 1
        #expect(TaskSortOption.custom.sort([b, a]).map(\.name) == ["a", "b"])
    }

    @Test("custom ties (never-dragged or newly created tasks) fall back to newest first")
    func customTieBreaksNewestFirst() {
        let old = task("old", created: 100, lastRun: nil)
        let new = task("new", created: 900, lastRun: nil)
        #expect(TaskSortOption.custom.sort([old, new]).map(\.name) == ["new", "old"])
    }

    @Test("move with everything visible matches Array.move")
    func moveUnfiltered() {
        let all = ordered(["a", "b", "c", "d"])
        let down = TaskSortOption.move(all, visible: all, fromOffsets: [0], toOffset: 3)
        #expect(down.map(\.name) == ["b", "c", "a", "d"])
        let up = TaskSortOption.move(all, visible: all, fromOffsets: [3], toOffset: 0)
        #expect(up.map(\.name) == ["d", "a", "b", "c"])
        let toEnd = TaskSortOption.move(all, visible: all, fromOffsets: [1], toOffset: 4)
        #expect(toEnd.map(\.name) == ["a", "c", "d", "b"])
    }

    @Test("move keeps rows hidden by a filter next to their visible neighbours")
    func moveFiltered() {
        let all = ordered(["a", "x", "b", "y", "c"])
        let visible = all.filter { ["a", "b", "c"].contains($0.name) }
        // Drop "c" before "b" in the filtered view: it lands right before "b",
        // hidden "x" stays between "a" and the moved row's new spot.
        let result = TaskSortOption.move(all, visible: visible, fromOffsets: [2], toOffset: 1)
        #expect(result.map(\.name) == ["a", "x", "c", "b", "y"])
        // Drop "a" at the end of the filtered view: right after "c".
        let toEnd = TaskSortOption.move(all, visible: visible, fromOffsets: [0], toOffset: 3)
        #expect(toEnd.map(\.name) == ["x", "b", "y", "c", "a"])
    }

    @Test("move with a destination inside the moved block is a no-op")
    func moveOntoItself() {
        let all = ordered(["a", "b", "c"])
        let result = TaskSortOption.move(all, visible: all, fromOffsets: [1], toOffset: 2)
        #expect(result.map(\.name) == ["a", "b", "c"])
    }

    @Test("move ignores out-of-range offsets")
    func moveOutOfRange() {
        let all = ordered(["a", "b"])
        #expect(TaskSortOption.move(all, visible: all, fromOffsets: [5], toOffset: 0).map(\.name) == ["a", "b"])
        #expect(TaskSortOption.move(all, visible: all, fromOffsets: [0], toOffset: 99).map(\.name) == ["b", "a"])
    }
}
