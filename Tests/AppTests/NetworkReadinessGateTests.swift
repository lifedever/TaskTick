import Testing
import Foundation
@testable import TaskTickApp

/// Deterministic stand-in for `NetworkReadinessGate.liveScheduler`.
@MainActor
private final class ManualClock {
    private struct Item {
        let id: Int
        let fireAt: TimeInterval
        let action: @MainActor () -> Void
    }

    private(set) var now: TimeInterval = 0
    private var items: [Item] = []
    private var nextID = 0

    var scheduler: NetworkReadinessGate.Scheduler {
        { [unowned self] delay, action in
            let id = self.nextID
            self.nextID += 1
            self.items.append(Item(id: id, fireAt: self.now + delay, action: action))
            return { [weak self] in self?.items.removeAll { $0.id == id } }
        }
    }

    var pendingCount: Int { items.count }

    func advance(by delta: TimeInterval) {
        now += delta
        while let next = items.filter({ $0.fireAt <= now }).min(by: { $0.fireAt < $1.fireAt }) {
            items.removeAll { $0.id == next.id }
            next.action()
        }
    }
}

@Suite("NetworkReadinessGate (issue #58)")
@MainActor
struct NetworkReadinessGateTests {
    private func makeGate(
        _ clock: ManualClock,
        outcomes: @escaping @MainActor (NetworkReadinessGate.Outcome) -> Void
    ) -> NetworkReadinessGate {
        NetworkReadinessGate(settle: 3, timeout: 60, schedule: clock.scheduler, onFinish: outcomes)
    }

    @Test("Usable path opens the gate only after it has settled")
    func readyAfterSettle() {
        let clock = ManualClock()
        var outcomes: [NetworkReadinessGate.Outcome] = []
        let gate = makeGate(clock) { outcomes.append($0) }

        gate.pathChanged(isUsable: true)
        clock.advance(by: 2.9)
        #expect(outcomes.isEmpty)
        clock.advance(by: 0.2)
        #expect(outcomes == [.ready])
    }

    // The real wake: the pre-sleep path still reads satisfied, then drops,
    // then Wi-Fi comes back a few seconds later.
    @Test("Stale satisfied path that drops does not open the gate")
    func flapBeforeSettleKeepsWaiting() {
        let clock = ManualClock()
        var outcomes: [NetworkReadinessGate.Outcome] = []
        let gate = makeGate(clock) { outcomes.append($0) }

        gate.pathChanged(isUsable: true)
        clock.advance(by: 0.5)
        gate.pathChanged(isUsable: false)
        clock.advance(by: 4.5)
        #expect(outcomes.isEmpty)

        gate.pathChanged(isUsable: true)
        clock.advance(by: 3)
        #expect(outcomes == [.ready])
        #expect(clock.now == 8)
    }

    @Test("Repeated usable updates don't push readiness back")
    func usableToUsableKeepsCountdown() {
        let clock = ManualClock()
        var outcomes: [NetworkReadinessGate.Outcome] = []
        let gate = makeGate(clock) { outcomes.append($0) }

        gate.pathChanged(isUsable: true)
        clock.advance(by: 2)
        gate.pathChanged(isUsable: true)
        clock.advance(by: 1)
        #expect(outcomes == [.ready])
    }

    @Test("No network at all times out so local tasks still run")
    func timesOutWithoutNetwork() {
        let clock = ManualClock()
        var outcomes: [NetworkReadinessGate.Outcome] = []
        let gate = makeGate(clock) { outcomes.append($0) }

        gate.pathChanged(isUsable: false)
        clock.advance(by: 59)
        #expect(outcomes.isEmpty)
        clock.advance(by: 1)
        #expect(outcomes == [.timedOut])
    }

    @Test("Finishes exactly once and clears its timers")
    func finishesOnce() {
        let clock = ManualClock()
        var outcomes: [NetworkReadinessGate.Outcome] = []
        let gate = makeGate(clock) { outcomes.append($0) }

        gate.pathChanged(isUsable: true)
        clock.advance(by: 3)
        gate.pathChanged(isUsable: false)
        gate.pathChanged(isUsable: true)
        clock.advance(by: 120)
        #expect(outcomes == [.ready])
        #expect(clock.pendingCount == 0)
    }

    @Test("Cancel suppresses the callback")
    func cancelSuppressesCallback() {
        let clock = ManualClock()
        var outcomes: [NetworkReadinessGate.Outcome] = []
        let gate = makeGate(clock) { outcomes.append($0) }

        gate.pathChanged(isUsable: true)
        gate.cancel()
        clock.advance(by: 120)
        #expect(outcomes.isEmpty)
        #expect(clock.pendingCount == 0)
    }
}

@Suite("Overdue tolerance after wake (issue #58)")
struct OverdueToleranceTests {
    @Test("On-time window is 60s without grace")
    func baseTolerance() {
        #expect(TaskScheduler.firesOverdueRun(overdueSeconds: 60, grace: 0, runMissedExecution: false))
        #expect(!TaskScheduler.firesOverdueRun(overdueSeconds: 61, grace: 0, runMissedExecution: false))
    }

    // Due 58s before the wake (on time at the wake), then held 8s for the
    // network: it must still fire at 66s. Due 61s before the wake was
    // already missed at the wake and stays missed.
    @Test("Network wait widens the window by its own length")
    func graceKeepsOnTimeRunsOnTime() {
        #expect(TaskScheduler.firesOverdueRun(overdueSeconds: 66, grace: 8, runMissedExecution: false))
        #expect(!TaskScheduler.firesOverdueRun(overdueSeconds: 69, grace: 8, runMissedExecution: false))
    }

    @Test("runMissedExecution fires regardless of lateness")
    func runMissedAlwaysFires() {
        #expect(TaskScheduler.firesOverdueRun(overdueSeconds: 36_000, grace: 0, runMissedExecution: true))
    }
}
