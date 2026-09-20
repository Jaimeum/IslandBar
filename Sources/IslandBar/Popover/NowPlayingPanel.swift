import AppKit
import SwiftUI

enum NowPlayingMetrics {
    static let artwork: CGFloat = 80
    static let faderGap: CGFloat = 10

    /// A hero without a fader is the honest shape when the mixer cannot see the playing
    /// app: a control that does nothing is worse than no control.
    static func height(hasFader: Bool) -> CGFloat {
        ControlGlass.panelPadding * 2
            + artwork
            + (hasFader ? faderGap + ControlGlass.sliderHeight : 0)
    }
}

/// The source that is actually playing, drawn large: artwork, title, artist, the live bars,
/// transport, and its own fader.
///
/// Everything else on the card is a row; this is the one source that earns a tile, because
/// it is the only one MediaRemote can tell us anything about. The rest of the list is
/// deliberately the same control at a smaller size, so "the thing playing" and "the other
/// things making noise" are visibly the same kind of object.
struct NowPlayingPanel: View {
    let row: MixerRow?
    @Environment(NowPlayingStore.self) private var store
    @Environment(AudioMixer.self) private var mixer

    var body: some View {
        ControlPanel {
            VStack(spacing: NowPlayingMetrics.faderGap) {
                HStack(alignment: .top, spacing: 12) {
                    artwork
                    details
                }
                .frame(height: NowPlayingMetrics.artwork)
                if let row {
                    fader(row)
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(text: displayTitle, font: .system(size: 14, weight: .semibold))
                .frame(height: 18)
            Spacer(minLength: 0).frame(height: 2)
            Text(store.session?.artist ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 15, alignment: .leading)
            Spacer(minLength: 0).frame(height: 3)
            meta
            Spacer(minLength: 0)
            transport
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// The bars and the app's name on one line: the visualiser is IslandBar's signature and
    /// the source's name belongs beside it, not in a badge of its own.
    private var meta: some View {
        HStack(spacing: 7) {
            HeroBars()
            Text(store.session?.appName ?? "")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(height: 16)
    }

    private var transport: some View {
        HStack(spacing: 18) {
            transportButton("backward.fill", size: 13) { store.previousTrack() }
            transportButton(store.isPlaying ? "pause.fill" : "play.fill", size: 16) { store.togglePlayPause() }
            transportButton("forward.fill", size: 13) { store.nextTrack() }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }

    private func fader(_ row: MixerRow) -> some View {
        HStack(spacing: ControlGlass.gutter) {
            ControlSlider(
                travel: CGFloat(sqrt(max(row.gain, 0))),
                isDimmed: row.isMuted,
                isEnabled: row.isAvailable,
                leadingSymbol: "speaker.fill",
                accessibilityName: row.name,
                onScrub: { mixer.setGain(Float($0 * $0), for: row.id) }
            )
            ControlCircleButton(
                symbol: muteSymbol(isMuted: row.isMuted),
                isOn: row.isMuted,
                variableValue: row.isMuted ? 1 : Double(sqrt(max(row.gain, 0))),
                accessibilityName: row.isMuted ? "Unmute \(row.name)" : "Mute \(row.name)"
            ) {
                mixer.toggleMute(row.id)
            }
            .disabled(!row.isAvailable)
        }
        .frame(height: ControlGlass.sliderHeight)
        .opacity(row.isAvailable ? 1 : 0.35)
    }

    private struct HeroBars: View {
        @Environment(NowPlayingStore.self) private var store

        var body: some View {
            IslandBarsView(
                flat: !store.isPlaying,
                animating: store.isPlaying && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                palette: store.palette,
                metrics: BarMetrics(barWidth: 3, gap: 2, minHeight: 2.5, maxHeight: 16),
                glow: true
            )
        }
    }

    private var displayTitle: String {
        guard let session = store.session else { return "Not Playing" }
        if !session.title.isEmpty { return session.title }
        if !session.artist.isEmpty { return session.artist }
        return store.isPlaying ? "Playing in \(session.appName)" : session.appName
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Group {
            if let image = store.session?.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.18)
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(width: NowPlayingMetrics.artwork, height: NowPlayingMetrics.artwork)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 7, y: 3)
    }
}
