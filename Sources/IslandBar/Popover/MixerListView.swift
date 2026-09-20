import AppKit
import SwiftUI

/// Metrics for the mixer strip, kept beside the view for the same reason
/// `ExpandedIslandMetrics` is: the card's height is computed from them outside SwiftUI.
enum MixerMetrics {
    /// Tall enough to grab anywhere, following Control Centre's sliders rather than the
    /// hairline track a conventional slider draws.
    static let rowHeight: CGFloat = 38
    static let rowSpacing: CGFloat = 6
    static let corner: CGFloat = 11
    static let icon: CGFloat = 22
    static let button: CGFloat = 30
    static let gutter: CGFloat = 9
    static let hairline: CGFloat = 1
    static let topInset: CGFloat = 12
    static let bottomInset: CGFloat = 14
    /// Past this the strip scrolls in place and the card stops growing, so the popover can
    /// never outgrow the screen.
    static let maxRows = 4

    /// Zero rows means zero height: the card must be pixel-identical to its pre-mixer self
    /// when nothing is playing.
    static func sectionHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        let visible = CGFloat(min(rows, maxRows))
        return hairline + topInset + visible * rowHeight + (visible - 1) * rowSpacing + bottomInset
    }
}

/// The per-app strip below the now-playing block.
///
/// Each app is one row in Control Centre's shape: the app's icon, a thick glass slider
/// filled to its level, and a round mute button. Wordless on purpose — the icon is the
/// identity, the fill is the level, the glyph is the switch — so the row needs no label,
/// never truncates, and reads at a glance. The name is in the tooltip and the
/// accessibility label.
struct MixerListView: View {
    @Environment(AudioMixer.self) private var mixer

    var body: some View {
        if !mixer.rows.isEmpty {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(height: MixerMetrics.hairline)
                rows
            }
            .transition(.identity)
        }
    }

    @ViewBuilder
    private var rows: some View {
        // The card grows to fit up to `maxRows`, so scrolling only ever applies beyond that.
        // Below it a plain stack is both correct and one less thing between the pointer and
        // a slider.
        if mixer.rows.count > MixerMetrics.maxRows {
            ScrollView(.vertical) { list }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .animation(listAnimation, value: mixer.rows.map(\.id))
        } else {
            list.animation(listAnimation, value: mixer.rows.map(\.id))
        }
    }

    private var list: some View {
        VStack(spacing: MixerMetrics.rowSpacing) {
            ForEach(mixer.rows) { row in
                MixerRowView(row: row)
            }
        }
        .padding(.top, MixerMetrics.topInset)
        .padding(.bottom, MixerMetrics.bottomInset)
        .padding(.horizontal, ExpandedIslandMetrics.padding)
    }

    private var listAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .smooth(duration: 0.28)
    }
}

private struct MixerRowView: View {
    let row: MixerRow
    @Environment(AudioMixer.self) private var mixer

    var body: some View {
        HStack(spacing: MixerMetrics.gutter) {
            icon
            AppVolumeSlider(row: row) { mixer.setGain($0, for: row.id) }
            MuteButton(row: row) { mixer.toggleMute(row.id) }
        }
        .frame(height: MixerMetrics.rowHeight)
        .help(row.name)
        .opacity(row.isAvailable ? 1 : 0.35)
        .disabled(!row.isAvailable)
    }

    private var icon: some View {
        Group {
            if let image = row.icon {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.22))
            }
        }
        .frame(width: MixerMetrics.icon, height: MixerMetrics.icon)
        .opacity(row.isMuted ? 0.45 : 1)
        .animation(.easeOut(duration: 0.16), value: row.isMuted)
        .accessibilityHidden(true)
    }
}

/// A thick glass slider. The whole body is the control, so there is no hairline track to
/// aim at and no knob to chase — the point being that it can be grabbed anywhere.
private struct AppVolumeSlider: View {
    let row: MixerRow
    let onChange: (Float) -> Void

    @State private var dragging = false
    @State private var hovering = false

    /// Travel is the square root of gain, so half-way sounds roughly half as loud and the
    /// quiet end gets the resolution where it is actually wanted.
    private var position: CGFloat { CGFloat(sqrt(max(row.gain, 0))) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MixerMetrics.corner, style: .continuous)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                shape.fill(.white.opacity(hovering || dragging ? 0.14 : 0.10))
                // A rounded rect clipped to the track rather than a capsule, so the fill's
                // leading corners stay flush with the track's at every width.
                shape
                    .fill(.white.opacity(row.isMuted ? 0.26 : 0.95))
                    .frame(width: fillWidth(in: width))
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .contentShape(shape)
            .gesture(
                // Zero minimum distance so a click jumps to the cursor and keeps tracking,
                // which is what makes an unlabelled control obvious.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        let p = min(max(value.location.x / max(width, 1), 0), 1)
                        onChange(Float(p * p))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: MixerMetrics.rowHeight)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // Implicit animation lags the cursor during a drag; keep it for programmatic jumps.
        .animation(dragging ? nil : .smooth(duration: 0.18), value: row.gain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        // Travel, not gain: the adjustable action steps travel, so reporting gain would
        // make the first arrow key appear to jump by a wildly different amount.
        .accessibilityValue(Double(position).formatted(.percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = 0.05
            let next = switch direction {
            case .increment: min(position + step, 1)
            case .decrement: max(position - step, 0)
            default: position
            }
            onChange(Float(next * next))
        }
    }

    /// Empty still reads as empty, but a sliver never looks like a rendering fault: below a
    /// corner's worth of travel the fill collapses entirely.
    private func fillWidth(in width: CGFloat) -> CGFloat {
        guard position > 0.001 else { return 0 }
        return max(MixerMetrics.corner * 2, position * width)
    }
}

/// The circular button beside each slider, matching the round accessory buttons Control
/// Centre puts next to its sliders.
private struct MuteButton: View {
    let row: MixerRow
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.white.opacity(row.isMuted ? 0.95 : (hovering ? 0.18 : 0.10)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                // The glyph's waves fill with the slider, which ties the two controls
                // together without a word between them.
                Image(
                    systemName: row.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                    variableValue: row.isMuted ? 1 : Double(sqrt(max(row.gain, 0)))
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(row.isMuted ? AnyShapeStyle(.black.opacity(0.78)) : AnyShapeStyle(.white))
            }
            .frame(width: MixerMetrics.button, height: MixerMetrics.button)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentTransition(.symbolEffect(.replace))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.16), value: row.isMuted)
        .accessibilityLabel(row.isMuted ? "Unmute \(row.name)" : "Mute \(row.name)")
    }
}
