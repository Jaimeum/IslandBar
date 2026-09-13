import AppKit
import SwiftUI

enum CompactIslandMetrics {
    /// Thin bars on a 3.5 pt pitch: whole pixels at 2x, so edges stay crisp.
    static let bars = BarMetrics(barWidth: 2, gap: 1.5, minHeight: 2, maxHeight: 14)
    /// Bars only, no artwork: N bars + (N-1) gaps, plus 5 pt insets each side. The
    /// capsule is invisible on a dark menu bar, so every point of inset reads as a gap.
    static let pillWidth: CGFloat = bars.totalWidth + 10
    static let pillHeight: CGFloat = 18

    /// Idle mark: a miniature capsule holding three frozen bars (middle raised), the
    /// visualizer at rest. The pill contracts to this, then the status item's slot
    /// contracts around it.
    static let idleBarHeights: [CGFloat] = [5, 8, 6]
    static let idleBarsWidth: CGFloat = CGFloat(idleBarHeights.count) * bars.barWidth
        + CGFloat(idleBarHeights.count - 1) * bars.gap
    static let idleMarkSize = CGSize(width: idleBarsWidth + 8, height: 13)
    /// Margin between the idle mark and the slot's trailing edge, mirrored on the leading
    /// side once the slot contracts. The mark is drawn at this trailing inset even while
    /// the slot is still full, so collapsing the slot can never move it: the slot's
    /// trailing edge is the one status-item layout anchors.
    static let idleInset: CGFloat = 4
    static let idleSlotWidth: CGFloat = idleMarkSize.width + 2 * idleInset
    /// How far the live bar row shrinks towards the trailing edge as it fades into the
    /// mark. The capsule alone is already animating, but on a dark menu bar its black is
    /// invisible and the only visible shrink is the bars themselves.
    static let idleBarScale: CGFloat = 0.3
}

struct CompactIslandView: View {
    @Environment(NowPlayingStore.self) private var store
    @Environment(Preferences.self) private var preferences
    /// The menu bar's own appearance, inherited from the status item's button: a light
    /// menu bar is `light`, a dark one `dark`. Deliberately not forced to dark — the
    /// capsule below is what makes a dark menu bar work, and on a light one it would
    /// sit there as a hard black pill.
    @Environment(\.colorScheme) private var colorScheme
    var buttonHeight: CGFloat

    /// On a light menu bar the pill's black capsule is dropped and the bars darken so
    /// they stay readable against white.
    private var onLightMenuBar: Bool { DebugLog.forcedPillIsLight ?? (colorScheme == .light) }

    var body: some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let idle = !store.isPlaying
        // This body only runs on the rare changes below (play state, palette, background
        // toggle, menu bar appearance); level frames go straight to the layer view.
        //
        // The slot's trailing edge is the one status-item layout pins, and the hosting
        // view is resized by the controller (see StatusItemController). GeometryReader is
        // what makes the root take the slot's size instead of the content's: the bar row
        // is wider than a contracted slot, and left to size itself the root would grow
        // around the bars and drag the trailing-aligned mark left with it. Inside the
        // geometry, everything full-size (the capsule, the bars) spans the width, while
        // the mark sits at a fixed trailing inset — so collapsing the slot moves nothing.
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                if preferences.showPillBackground && !onLightMenuBar {
                    Capsule()
                        .fill(Color.black.opacity(0.92))
                        .frame(
                            width: idle ? CompactIslandMetrics.idleMarkSize.width : CompactIslandMetrics.pillWidth,
                            height: idle ? CompactIslandMetrics.idleMarkSize.height : CompactIslandMetrics.pillHeight
                        )
                        .padding(.trailing, idle ? CompactIslandMetrics.idleInset : 0)
                }
                IslandBarsView(
                    flat: false,
                    animating: store.isPlaying && !reduceMotion,
                    palette: store.palette,
                    metrics: CompactIslandMetrics.bars,
                    lightBackground: onLightMenuBar
                )
                .frame(width: CompactIslandMetrics.pillWidth, height: CompactIslandMetrics.pillHeight)
                .scaleEffect(idle ? CompactIslandMetrics.idleBarScale : 1, anchor: .trailing)
                .opacity(idle ? 0 : 1)
                IdleBarsMark(light: onLightMenuBar)
                    .frame(
                        width: CompactIslandMetrics.idleMarkSize.width,
                        height: CompactIslandMetrics.idleMarkSize.height
                    )
                    .padding(.trailing, CompactIslandMetrics.idleInset)
                    .scaleEffect(idle ? 1 : 0.6, anchor: .trailing)
                    .opacity(idle ? 1 : 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.65), value: store.isPlaying)
        .onChange(of: store.isPlaying) { _, playing in
            DebugLog.line("pill presence=\(playing ? "playing" : "idle")")
        }
    }
}

/// The idle pill in miniature: three frozen bars drawn as capsules, in the same neutral
/// colours as the full-size idle line. The last artwork's palette is deliberately not
/// reused here — idle should read as neutral across every session.
private struct IdleBarsMark: View {
    var light: Bool

    var body: some View {
        HStack(alignment: .center, spacing: CompactIslandMetrics.bars.gap) {
            ForEach(CompactIslandMetrics.idleBarHeights.indices, id: \.self) { index in
                Capsule()
                    .frame(
                        width: CompactIslandMetrics.bars.barWidth,
                        height: CompactIslandMetrics.idleBarHeights[index]
                    )
            }
        }
        .foregroundStyle(Color(nsColor: light ? BarsLayerView.lightIdleColor : BarsLayerView.idleColor))
    }
}
