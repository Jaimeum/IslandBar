import SwiftUI

/// Single source of truth for the popover size. The card's height now depends on how many
/// apps the mixer is showing, so the SwiftUI root no longer pins it: `StatusItemController`
/// sets `NSPopover.contentSize` and the hosting view's frame together from `size(rows:)`,
/// and the root simply fills what it is given. That keeps one authority for a height that
/// changes, instead of three that have to be kept in agreement.
enum ExpandedIslandMetrics {
    static let width: CGFloat = 300
    static let height: CGFloat = 150
    static let padding: CGFloat = 14
    static let artwork: CGFloat = 72
    /// The now-playing block keeps exactly the height the whole card used to have.
    static let nowPlayingHeight: CGFloat = height
    static var size: NSSize { size(rows: 0) }

    static func size(rows: Int) -> NSSize {
        NSSize(width: width, height: nowPlayingHeight + MixerMetrics.sectionHeight(rows: rows))
    }
}

struct ExpandedIslandView: View {
    @Environment(NowPlayingStore.self) private var store

    var body: some View {
        // Top-aligned: the popover's height is monotonic while it is open, so when the
        // mixer empties the card stays tall for a moment. A centred stack would slide the
        // now-playing block down into the gap.
        ZStack(alignment: .top) {
            HUDBackground()
            VStack(spacing: 0) {
                nowPlaying
                    .frame(height: ExpandedIslandMetrics.nowPlayingHeight)
                MixerListView()
            }
        }
        .frame(width: ExpandedIslandMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    private var nowPlaying: some View {
        HStack(alignment: .center, spacing: 14) {
            artwork
            VStack(alignment: .leading, spacing: 5) {
                MarqueeText(text: displayTitle, font: .headline.bold())
                    .frame(height: 18)
                Text(store.session?.artist ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 16, alignment: .leading)
                Text(store.session?.appName ?? "")
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.12), in: Capsule())
                    .frame(height: 18, alignment: .leading)
                ExpandedBars()
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 22) {
                    transportButton("backward.end.fill") { store.previousTrack() }
                    transportButton(store.isPlaying ? "pause.fill" : "play.fill") { store.togglePlayPause() }
                    transportButton("forward.end.fill") { store.nextTrack() }
                }
                .font(.title3)
                .frame(height: 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(ExpandedIslandMetrics.padding)
        .foregroundStyle(.white)
    }

    private struct ExpandedBars: View {
        @Environment(NowPlayingStore.self) private var store

        var body: some View {
            IslandBarsView(
                flat: !store.isPlaying,
                animating: store.isPlaying && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                palette: store.palette,
                metrics: BarMetrics(barWidth: 4, gap: 2.5, minHeight: 3, maxHeight: 24),
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

    private func transportButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Group {
            if let image = store.session?.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Color(white: 0.2)
            }
        }
        .frame(width: ExpandedIslandMetrics.artwork, height: ExpandedIslandMetrics.artwork)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
    }
}

struct HUDBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MarqueeText: View {
    let text: String
    let font: Font
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width + 1
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !overflow)) { timeline in
                let x = overflow
                    ? marqueeOffset(
                        time: timeline.date.timeIntervalSinceReferenceDate,
                        textWidth: textWidth,
                        viewWidth: geo.size.width
                    )
                    : 0
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: WidthKey.self, value: inner.size.width)
                        }
                    )
                    .offset(x: x)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            }
            .clipped()
            .mask(edgeFade(overflow: overflow))
            .onPreferenceChange(WidthKey.self) { textWidth = $0 }
        }
    }

    /// Soft fade on the trailing edge while the text is scrolling.
    private func edgeFade(overflow: Bool) -> some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: overflow ? 0.9 : 1),
                .init(color: overflow ? .clear : .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func marqueeOffset(time: TimeInterval, textWidth: CGFloat, viewWidth: CGFloat) -> CGFloat {
        let extra = textWidth - viewWidth
        guard extra > 0 else { return 0 }
        let pause = 1.4
        let speed = 28.0
        let travel = Double(extra + 16)
        let scroll = travel / speed
        let hold = 1.0
        let period = pause + scroll + hold
        let t = time.truncatingRemainder(dividingBy: period)
        if t < pause { return 0 }
        if t > pause + scroll { return -CGFloat(travel) }
        let p = (t - pause) / scroll
        // Ease in/out so the start and stop are not abrupt.
        let eased = 0.5 - 0.5 * cos(p * .pi)
        return -CGFloat(eased) * CGFloat(travel)
    }
}
