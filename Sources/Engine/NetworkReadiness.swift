import Foundation
import Network

/// Decides when the network is back after the Mac wakes (issue #58).
///
/// Wi-Fi drops while the Mac sleeps and takes a few seconds to come back
/// once it wakes; a script fired on the wake notification runs into that
/// gap and fails. The gate reports `.ready` once the path has stayed usable
/// for `settle` seconds, or `.timedOut` after `timeout` so that a Mac with
/// no network at all still runs its due tasks.
///
/// Settling matters: for the first half second after a wake the system
/// still reports the pre-sleep path as satisfied, and only then tears it
/// down — a gate that opened on the first satisfied update would wave
/// tasks straight into the outage.
@MainActor
final class NetworkReadinessGate {
    enum Outcome: Equatable, Sendable {
        case ready
        case timedOut
    }

    /// Runs `action` after `delay`; the returned closure cancels it.
    typealias Scheduler = @MainActor (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> (() -> Void)

    /// Suspending clock: time asleep doesn't count. If the lid closes again
    /// mid-wait, the wait must not expire during a Power Nap dark wake and
    /// release tasks into a network that's down; the next full wake starts
    /// a fresh wait anyway.
    static let liveScheduler: Scheduler = { delay, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay), clock: .suspending)
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }

    private let settle: TimeInterval
    private let schedule: Scheduler
    private var onFinish: (@MainActor (Outcome) -> Void)?
    private var cancelSettle: (() -> Void)?
    private var cancelTimeout: (() -> Void)?

    init(
        settle: TimeInterval,
        timeout: TimeInterval,
        schedule: @escaping Scheduler = NetworkReadinessGate.liveScheduler,
        onFinish: @escaping @MainActor (Outcome) -> Void
    ) {
        self.settle = settle
        self.schedule = schedule
        self.onFinish = onFinish
        cancelTimeout = schedule(timeout) { [weak self] in self?.finish(.timedOut) }
    }

    /// Feed every path update here. A usable path starts the settle
    /// countdown; an unusable one cancels it. Usable-to-usable updates
    /// (an IPv6 address arriving, a tunnel coming up) leave a running
    /// countdown alone so they can't keep pushing readiness back.
    func pathChanged(isUsable: Bool) {
        guard onFinish != nil else { return }
        if isUsable {
            guard cancelSettle == nil else { return }
            cancelSettle = schedule(settle) { [weak self] in self?.finish(.ready) }
        } else {
            cancelSettle?()
            cancelSettle = nil
        }
    }

    /// Stops the gate without calling `onFinish`.
    func cancel() {
        onFinish = nil
        cancelTimers()
    }

    private func finish(_ outcome: Outcome) {
        guard let onFinish else { return }
        self.onFinish = nil
        cancelTimers()
        onFinish(outcome)
    }

    private func cancelTimers() {
        cancelSettle?()
        cancelSettle = nil
        cancelTimeout?()
        cancelTimeout = nil
    }

    /// Satisfied *through a physical interface*. A VPN or proxy tunnel
    /// (`utun*`, type `.other`) can report a satisfied path while Wi-Fi is
    /// still down — the unified log of a real wake shows exactly that — but
    /// it then carries no underlying interface, so `usesInterfaceType` is
    /// false for every physical type until Wi-Fi or Ethernet is back.
    nonisolated static func isUsable(_ path: NWPath) -> Bool {
        guard path.status == .satisfied else { return false }
        return [.wifi, .wiredEthernet, .cellular].contains { path.usesInterfaceType($0) }
    }
}

/// Feeds an `NWPathMonitor` into a `NetworkReadinessGate`. One wait at a
/// time: starting a new one drops the previous wait without calling it back.
@MainActor
final class WakeNetworkWait {
    private var monitor: NWPathMonitor?
    private var gate: NetworkReadinessGate?

    var isWaiting: Bool { gate != nil }

    func start(
        settle: TimeInterval,
        timeout: TimeInterval,
        onFinish: @escaping @MainActor (NetworkReadinessGate.Outcome) -> Void
    ) {
        cancel()
        let gate = NetworkReadinessGate(settle: settle, timeout: timeout) { [weak self] outcome in
            self?.cancel()
            onFinish(outcome)
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak gate] path in
            let usable = NetworkReadinessGate.isUsable(path)
            // Delivered on `.main` (see `start(queue:)` below).
            MainActor.assumeIsolated { gate?.pathChanged(isUsable: usable) }
        }
        self.gate = gate
        self.monitor = monitor
        monitor.start(queue: .main)
    }

    func cancel() {
        monitor?.cancel()
        monitor = nil
        gate?.cancel()
        gate = nil
    }
}
