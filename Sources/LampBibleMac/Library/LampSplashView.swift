import AppKit
import Combine
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

/// Shown while the library is being read, in place of an interface that would
/// otherwise assemble itself around an empty reader and a progress spinner in the
/// corner.
///
/// The app's icon, the name, and the verse the app is named for. The gleam under the name is Core Animation's, run by the render
/// server: the library is opened on the main thread while this shows, and
/// SwiftUI's own animations stuttered with it. With Reduce Motion the gleam
/// rests, brightening and dimming.
struct LampSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingSlowStartMessage = false

    var body: some View {
        // Centred as one group on what is drawn: no room left above the
        // icon or below the last line that the eye would not see, so the
        // icon, the words and the status sit in the middle of the window
        // together (owner, Nov 2026).
        VStack(spacing: 0) {
            LampSplashIcon(size: 80)

            Text("Lamp Bible")
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .padding(.top, 24)

            LampSplashShimmer(isAnimated: !reduceMotion)
                .frame(width: 180, height: 2)
                .padding(.top, 14)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("“Thy word is a lamp unto my feet,\nand a light unto my path.”")
                    .font(.system(size: 15, design: .serif).italic())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                Text("Psalm 119:105")
                    .font(.system(size: 11, weight: .medium, design: .serif))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 28)
            .accessibilityElement(children: .combine)

            Text(isShowingSlowStartMessage
                ? "Preparing your library. This happens once after an update."
                : "Opening your library…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                // No room held for a second line: room left empty at the
                // bottom put the group off centre. Both messages fit one line,
                // and if one wraps the change is animated, so the group
                // re-centres smoothly.
                .padding(.top, 30)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        // The bundled modules are unpacked and verified on a first run or after an
        // update, which takes long enough to be worth explaining.
        .task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { isShowingSlowStartMessage = true }
        }
    }
}

/// The app's icon, small, as a tile with the system's rounded corners.
///
/// It was the icon's flame alone, in the accent, at 120 points with 44 above
/// the name: large, far from the words, and plain (owner, 2026-11-26, who
/// chose this from seven static options). The artwork is the icon's own
/// (`lampicon`, the 128 to 512 pixel icon images), clipped as macOS and iOS
/// clip an icon, so it is the icon and not a drawing of it. Where the asset
/// catalog is not built, as in a SwiftPM build, the application's icon
/// stands in, which carries its own shape.
struct LampSplashIcon: View {
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if NSImage(named: "lampicon") != nil {
                let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                Image("lampicon")
                    .resizable()
                    .interpolation(.high)
                    .clipShape(shape)
                    // A hairline in the dark, where the icon's dark spine
                    // would otherwise run into the window.
                    .overlay(shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.08 : 0), lineWidth: 1))
                    .shadow(
                        color: colorScheme == .dark ? .black.opacity(0.45) : Color(red: 0.47, green: 0.04, blue: 0.06).opacity(0.22),
                        radius: 10, y: 8
                    )
            } else {
                Image(nsImage: NSApp.applicationIconImage).resizable()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The accent, as the asset catalog gives it for the view's appearance.
private func lampSplashAccent(for appearance: NSAppearance) -> NSColor {
    var resolved = NSColor.systemRed
    appearance.performAsCurrentDrawingAppearance {
        let accent = NSColor(named: "AccentColor") ?? NSColor(Color.accentColor)
        resolved = accent.usingColorSpace(.sRGB) ?? accent
    }
    return resolved
}

/// A hairline with a gleam of the accent passing along it, for "working on
/// it" without a spinner. Unanimated, the gleam rests in the middle and only
/// brightens and dims.
private struct LampSplashShimmer: NSViewRepresentable {
    let isAnimated: Bool

    func makeNSView(context: Context) -> ShimmerView { ShimmerView() }

    func updateNSView(_ view: ShimmerView, context: Context) {
        view.isAnimated = isAnimated
    }

    final class ShimmerView: NSView {
        private let track = CALayer()
        private let gleam = CAGradientLayer()
        /// The width the gleam's sweep was set up for: a layout pass at the
        /// same width leaves it running rather than starting it again.
        private var animatedWidth: CGFloat = 0
        var isAnimated = true {
            didSet { if isAnimated != oldValue { animate() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.addSublayer(track)
            track.addSublayer(gleam)
            track.masksToBounds = true
            gleam.startPoint = CGPoint(x: 0, y: 0.5)
            gleam.endPoint = CGPoint(x: 1, y: 0.5)
            paint()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.frame = bounds
            track.cornerRadius = bounds.height / 2
            let width = bounds.width * 0.4
            gleam.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            gleam.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
            if bounds.width != animatedWidth { animate() }
        }

        /// Set up again on returning to a window, should the layer have let
        /// its animations go while it was out of one.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { animate() }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            paint()
        }

        private func paint() {
            let accent = lampSplashAccent(for: effectiveAppearance)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
            gleam.colors = [accent.withAlphaComponent(0).cgColor, accent.cgColor, accent.withAlphaComponent(0).cgColor]
            CATransaction.commit()
        }

        private func animate() {
            gleam.removeAllAnimations()
            animatedWidth = bounds.width
            guard bounds.width > 0 else { return }
            if isAnimated {
                let sweep = CABasicAnimation(keyPath: "position.x")
                sweep.fromValue = -bounds.width * 0.2
                sweep.toValue = bounds.width * 1.2
                sweep.duration = 1.6
                sweep.repeatCount = .infinity
                sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                gleam.add(sweep, forKey: "sweep")
            } else {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.35
                pulse.toValue = 1
                pulse.duration = 1.2
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                gleam.add(pulse, forKey: "pulse")
            }
        }
    }
}
