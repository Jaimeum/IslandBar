import AppKit
import CoreAudio
import Foundation
import Observation

/// One app's row, as the card draws it.
struct MixerRow: Identifiable, Equatable {
    var id: String
    var name: String
    var icon: NSImage?
    /// 0...1, the level the slider draws. A muted row keeps its stored level here rather
    /// than reporting zero, so unmuting visibly returns to where it was.
    var gain: Float
    var isMuted: Bool
    /// False once the system has refused IslandBar a tap, so rows show dimmed and inert
    /// rather than pretending to control something.
    var isAvailable: Bool
}

/// Owns what the user has asked for, and keeps the engine in step with it.
///
/// Nothing here is persisted. A mute is a moment, like the Windows mixer it borrows from:
/// persisting one is how someone ends up with a silent browser, no memory of why, and a
/// relaunch faithfully restoring it. Every launch starts from an unmuted baseline by
/// construction, so there is no restore path to get wrong.
@MainActor
@Observable
final class AudioMixer {
    private(set) var rows: [MixerRow] = []
    var rowCount: Int { rows.count }

    @ObservationIgnored private let queue = DispatchQueue(label: "dev.burbuja-lab.islandbar.mixer")
    @ObservationIgnored private let engine: MixerEngine
    @ObservationIgnored private let lister: MixerAppLister
    @ObservationIgnored private var snapshots: [MixerRowSnapshot] = []
    @ObservationIgnored private var gains: [String: Float] = [:]
    @ObservationIgnored private var muted: Set<String> = []
    /// Where the fader was before a mute, so unmuting restores the level rather than
    /// jumping to full.
    @ObservationIgnored private var preMuteGain: [String: Float] = [:]
    /// Set once the system refuses a tap. It stays set for the session: the refusal is
    /// about IslandBar, not about the apps that happened to be listed at the time, so a row
    /// appearing later must not offer controls that cannot work.
    @ObservationIgnored private var denied = false
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var started = false

    init(registry: AudioProcessRegistry) {
        engine = MixerEngine(queue: queue, registry: registry)
        lister = MixerAppLister(queue: queue, registry: registry)
    }

    func start() {
        guard !started, !DebugLog.mixerDisabled else { return }
        started = true
        lister.onRows = { [weak self] rows in
            MainActor.assumeIsolated { self?.receive(rows) }
        }
        engine.onFailure = { [weak self] reason in
            MainActor.assumeIsolated { self?.engineFailed(reason) }
        }
        engine.onDenied = { [weak self] in
            MainActor.assumeIsolated { self?.engineDenied() }
        }
        lister.start()
    }

    /// Synchronous on purpose: every tap must be destroyed before the process exits, or an
    /// app is left muted with nothing running to unmute it.
    func stop() {
        guard started else { return }
        started = false
        lister.stop()
        queue.sync { engine.stop() }
    }

    func setPopoverOpen(_ open: Bool) {
        guard started else { return }
        lister.setPopoverOpen(open)
    }

    /// The app behind the Now Playing session. Its row is held open across a pause, because
    /// it is the source the card leads with and a paused track is exactly when you reach for
    /// its level. Nothing is tapped by this: a row at full volume still costs nothing.
    func setNowPlaying(_ bundleID: String?) {
        lister.setPinned(bundleID)
    }

    // MARK: - Intent

    func setGain(_ gain: Float, for id: String) {
        let clamped = min(max(gain, 0), 1)
        gains[id] = clamped
        // Moving the fader off zero is how you unmute by hand; moving it *to* zero is just
        // zero, so that mute stays a toggle you can undo.
        if clamped > 0 { muted.remove(id) }
        rebuildRows()
        push()
    }

    func toggleMute(_ id: String) {
        if muted.contains(id) {
            muted.remove(id)
            gains[id] = preMuteGain[id] ?? gains[id] ?? 1
        } else {
            muted.insert(id)
            preMuteGain[id] = gains[id] ?? 1
        }
        rebuildRows()
        push()
    }

    // MARK: - Plumbing

    private func receive(_ snapshots: [MixerRowSnapshot]) {
        self.snapshots = snapshots
        for snapshot in snapshots where icons[snapshot.id] == nil {
            let icon = NSWorkspace.shared.icon(forFile: snapshot.appPath)
            icon.size = NSSize(width: 32, height: 32)
            icons[snapshot.id] = icon
        }
        let live = Set(snapshots.map(\.id))
        icons = icons.filter { live.contains($0.key) }
        // Forget an app's level once it is gone, so relaunching it starts from full.
        gains = gains.filter { live.contains($0.key) }
        muted = muted.filter { live.contains($0) }
        preMuteGain = preMuteGain.filter { live.contains($0.key) }
        rebuildRows()
        push()
    }

    private func rebuildRows() {
        rows = snapshots.map { snapshot in
            MixerRow(
                id: snapshot.id,
                name: snapshot.name,
                icon: icons[snapshot.id],
                // The stored level, not zero: a muted row keeps its slider where it was, so
                // the level unmuting will restore is visible rather than guessed at.
                gain: gains[snapshot.id] ?? 1,
                isMuted: muted.contains(snapshot.id),
                isAvailable: !denied
            )
        }
    }

    /// What the engine should actually render: silence while muted, otherwise the stored
    /// level. This is deliberately not what the slider draws.
    private func effectiveGain(_ id: String) -> Float {
        guard !muted.contains(id) else { return 0 }
        return gains[id] ?? 1
    }

    private func push() {
        guard !denied else { return }
        var targets: [MixerTarget] = []
        for snapshot in snapshots {
            var gain = effectiveGain(snapshot.id)
            if DebugLog.mixerMuteOnly { gain = gain < 0.999 ? 0 : 1 }
            guard gain < 0.999, !snapshot.processes.isEmpty else { continue }
            targets.append(MixerTarget(id: snapshot.id, processes: snapshot.processes, gain: gain))
        }
        let plan = targets
        lister.setControlled(Set(plan.map(\.id)))
        queue.async { [engine] in engine.apply(plan) }
    }

    private func engineFailed(_ reason: String) {
        // The engine has already torn itself down, which returns every app to the hardware.
        // Returning the rows to full keeps the card honest about that.
        gains = [:]
        muted = []
        preMuteGain = [:]
        rebuildRows()
        DebugLog.line("mixer reset after failure reason=\(reason)")
    }

    private func engineDenied() {
        denied = true
        gains = [:]
        muted = []
        preMuteGain = [:]
        rebuildRows()
    }
}
