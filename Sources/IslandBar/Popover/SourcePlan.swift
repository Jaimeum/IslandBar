import AppKit
import Foundation

/// What the card is going to draw, resolved once from the three things that feed it: the
/// Now Playing session, the apps holding an output connection, and the system's output.
///
/// It exists because the card's height is computed *outside* SwiftUI (see
/// `ExpandedIslandMetrics`), so the view and `StatusItemController` have to agree exactly
/// on the shape of what is about to be laid out. Deriving both from one value is how they
/// stay in agreement instead of drifting.
struct SourcePlan: Equatable {
    /// There is a Now Playing session, so the card leads with the hero tile. A paused
    /// session still counts: that is precisely when you want the transport.
    var hasHero: Bool
    /// The hero app's fader, when the mixer can see it. Nil when the mixer is off, when
    /// the tap was refused, or when the playing app is not the one holding the output
    /// connection — the hero then renders without a fader rather than a dead one.
    var heroRow: MixerRow?
    /// Every other app currently playing, in the order the mixer first saw them.
    var others: [MixerRow]
    var outputDeviceCount: Int
    var isPickingOutput: Bool

    /// Past this the sources panel scrolls in place and the card stops growing, so the
    /// popover can never outgrow the screen.
    static let maxVisibleSources = 4
    /// Same idea for the output list. Four devices is already an unusual Mac.
    static let maxVisibleDevices = 5

    @MainActor
    static func make(session: Session?, rows: [MixerRow], system: SystemAudioController) -> SourcePlan {
        let hero = session.flatMap { session in
            // The bundle identifier is the join: MediaRemote reports the app's, and the
            // mixer resolves a helper process up to its outermost `.app`, which is the same
            // identifier for every browser and player tested. The name is a fallback for
            // the ones where it is not.
            rows.first { $0.id == session.bundleID }
                ?? rows.first { $0.name.caseInsensitiveCompare(session.appName) == .orderedSame }
        }
        return SourcePlan(
            hasHero: session != nil,
            heroRow: hero,
            others: rows.filter { $0.id != hero?.id },
            outputDeviceCount: system.devices.count,
            isPickingOutput: system.isPickingOutput
        )
    }
}
