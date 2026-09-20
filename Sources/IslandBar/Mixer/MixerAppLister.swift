import CoreAudio
import Foundation

/// One app currently holding an output connection, as the mixer sees it.
struct MixerRowSnapshot: Sendable, Equatable {
    var id: String
    var name: String
    var appPath: String
    /// Every audio process object belonging to the app, sorted so the engine's change
    /// check does not fire on reordering alone.
    var processes: [AudioObjectID]
}

/// Watches which apps are playing, and publishes them as rows.
///
/// This polls rather than listening. `AudioProcessRegistry`'s two listener closures are
/// single-assignment and belong to `TapController`; taking one, or converting them to a
/// multicast, would mean editing the visualizer's path for a feature that does not need it.
/// `kAudioProcessPropertyIsRunningOutput` also emits no property-change notifications at
/// all, so a listener would not be enough on its own anyway.
final class MixerAppLister: @unchecked Sendable {
    /// Delivered on the main queue.
    var onRows: (@Sendable ([MixerRowSnapshot]) -> Void)?

    private let queue: DispatchQueue
    private let registry: AudioProcessRegistry
    private let resolver = AudioAppResolver()
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = MixerAppLister.closedInterval

    /// Last time each app was seen playing, and the apps the user is actively holding down.
    private var lastSeen: [String: Date] = [:]
    private var published: [MixerRowSnapshot] = []
    private var controlled: Set<String> = []
    /// Arrival order, so rows keep the positions they were first given.
    private var order: [String: UInt64] = [:]
    private var nextOrder: UInt64 = 0

    /// While the card is open a row should appear promptly; while it is closed the poll
    /// only needs to keep the engine's process sets fresh.
    private static let openInterval: TimeInterval = 0.5
    private static let closedInterval: TimeInterval = 2
    /// A process object is created shortly before it has any output, and a track change
    /// leaves a real gap — measured at 441 ms — so a row outlives a brief silence.
    private static let linger: TimeInterval = 1.8

    init(queue: DispatchQueue, registry: AudioProcessRegistry) {
        self.queue = queue
        self.registry = registry
    }

    func start() {
        queue.async { [weak self] in self?.restart() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func setPopoverOpen(_ open: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let wanted = open ? Self.openInterval : Self.closedInterval
            guard wanted != self.interval else { return }
            self.interval = wanted
            self.restart()
        }
    }

    /// The set the engine is currently holding below full volume, so their rows persist.
    func setControlled(_ ids: Set<String>) {
        queue.async { [weak self] in self?.controlled = ids }
    }

    private func restart() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    private func poll() {
        let processes = registry.snapshot()
        let now = Date()
        let me = getpid()

        resolver.prune(live: Set(processes.map(\.pid)))

        var grouped: [String: MixerRowSnapshot] = [:]
        var running: Set<String> = []
        for process in processes {
            // IslandBar holds an output connection of its own, because the visualizer's
            // aggregate device is one. A device-based filter cannot tell it apart, so it is
            // dropped by pid.
            guard process.pid != me else { continue }
            guard let identity = resolver.identity(for: process.pid) else { continue }
            running.insert(identity.id)
            // A live output connection is a steadier signal than `isRunningOutput`, and it
            // excludes the twenty-odd system daemons for free — no denylist needed.
            guard !registry.outputDevices(for: process.objectID).isEmpty else { continue }
            lastSeen[identity.id] = now
            grouped[identity.id, default: MixerRowSnapshot(
                id: identity.id,
                name: identity.name,
                appPath: identity.appPath,
                processes: []
            )].processes.append(process.objectID)
        }

        // `grouped` is a dictionary, so its values come out in an arbitrary order. Sorting
        // by identifier before arrival order is assigned keeps the list stable from one
        // launch to the next instead of shuffling on every start.
        var rows = grouped.values
            .map { row -> MixerRowSnapshot in
                var row = row
                row.processes.sort()
                return row
            }
            .sorted { $0.id < $1.id }

        // Carry recently-quiet apps so the list does not flicker between tracks.
        for previous in published where grouped[previous.id] == nil {
            // For a held-down app, being alive *replaces* the timer rather than gating it.
            // Capping it at a few seconds meant muting an app and then pausing it dropped
            // the row, which pruned the mute and retired the tap — releasing the mute
            // behind the user's back.
            if controlled.contains(previous.id) {
                guard running.contains(previous.id) else {
                    lastSeen[previous.id] = nil
                    continue
                }
                // Keep the clock rolling so that releasing control later starts a fresh
                // linger instead of expiring on the very next poll.
                lastSeen[previous.id] = now
                rows.append(previous)
                continue
            }
            guard let seen = lastSeen[previous.id] else { continue }
            if now.timeIntervalSince(seen) < Self.linger {
                rows.append(previous)
            } else {
                lastSeen[previous.id] = nil
            }
        }

        // First-seen order: a new app appends below the existing rows rather than sorting
        // into the middle of them, so a control can never slide out from under the pointer.
        for row in rows where order[row.id] == nil {
            order[row.id] = nextOrder
            nextOrder &+= 1
        }
        let live = Set(rows.map(\.id))
        order = order.filter { live.contains($0.key) }
        rows.sort { (order[$0.id] ?? 0, $0.id) < (order[$1.id] ?? 0, $1.id) }
        guard rows != published else { return }
        published = rows
        DebugLog.line("mixer rows=\(rows.count) apps=\(rows.map(\.id).joined(separator: ","))")
        DispatchQueue.main.async { [onRows] in onRows?(rows) }
    }
}
