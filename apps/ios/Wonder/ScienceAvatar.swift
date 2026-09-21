import SwiftUI
import WonderPairing

enum ScienceAvatarMotionState: String, CaseIterable, Identifiable {
    case idle, thinking, working, done, sleeping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .working: "Working"
        case .done: "Done"
        case .sleeping: "Sleeping"
        }
    }
}

enum ScienceAvatarMotionMode: Equatable {
    case `static`, looping, finite
}

struct ScienceAvatarMotionTransform: Equatable {
    let scale: CGFloat
    let rotation: CGFloat
    let offsetY: CGFloat

    static let zero = Self(scale: 1, rotation: 0, offsetY: 0)
}

/// Native geometry for the approved science family. Paths are compiled from
/// the reviewed SVG originals and cached as SwiftUI geometry:
/// there is no SVG/JSON parsing, WebView, or image rasterization at runtime.
struct ScienceAvatar: View {
    let shape: String?
    let palette: String?
    var size: CGFloat = 48
    var state: ScienceAvatarMotionState = .idle
    var animate: Bool = false
    var doneTrigger: UInt64 = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motionPhase = false
    @State private var stateDoneTrigger: UInt64 = 0

    private var shapeValue: ScienceAvatarShape { ScienceAvatarShape(rawValue: shape ?? "") ?? .sun }
    private var colors: ScienceAvatarPalette { ScienceAvatarPalette.resolve(palette) }
    private var moving: Bool { animate && !reduceMotion }
    private var motionMode: ScienceAvatarMotionMode { Self.motionMode(for: state, animate: animate, reduceMotion: reduceMotion) }
    private var identityLabel: String { "\(shapeValue.title) character, \(colors.name) palette" }

    var body: some View {
        animatedCanvas
            .frame(width: 256, height: 256)
            .scaleEffect(size / 256)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(identityLabel)
            .accessibilityAddTraits(.isImage)
            .onAppear {
                guard moving else { return }
                motionPhase = true
            }
            .onChange(of: state) { previous, next in
                guard moving else { return }
                // A historical Done state must not celebrate just because a
                // row appeared. Only a live state transition can bounce.
                if next == .done, previous != .done { stateDoneTrigger &+= 1 }
            }
            .onChange(of: moving) { _, next in
                motionPhase = next
            }
    }

    @ViewBuilder
    private var animatedCanvas: some View {
        if moving {
            transformedCanvas
                .keyframeAnimator(initialValue: DoneMotionValues(), trigger: doneTrigger &+ stateDoneTrigger) { content, value in
                    content
                        .scaleEffect(value.scale)
                        .rotationEffect(.degrees(value.rotation))
                        .offset(y: value.offsetY)
                } keyframes: { _ in
                    let segment = Self.doneMotionDuration / 4
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(1.08, duration: segment)
                        CubicKeyframe(0.96, duration: segment)
                        CubicKeyframe(1.04, duration: segment)
                        CubicKeyframe(1.0, duration: segment)
                    }
                    KeyframeTrack(\.rotation) {
                        CubicKeyframe(-3.0, duration: segment)
                        CubicKeyframe(2.0, duration: segment)
                        CubicKeyframe(-1.0, duration: segment)
                        CubicKeyframe(0.0, duration: segment)
                    }
                    KeyframeTrack(\.offsetY) {
                        CubicKeyframe(-3.0, duration: segment)
                        CubicKeyframe(1.0, duration: segment)
                        CubicKeyframe(-1.0, duration: segment)
                        CubicKeyframe(0.0, duration: segment)
                    }
                }
        } else {
            transformedCanvas
        }
    }

    private var transformedCanvas: some View {
        let transform = Self.motionTransform(for: state, active: animate, reduceMotion: reduceMotion, phase: motionPhase)
        return avatarCanvas
            .rotationEffect(.degrees(transform.rotation))
            .offset(y: transform.offsetY)
            .scaleEffect(transform.scale)
            .animation(Self.loopAnimation(for: state, mode: motionMode), value: state)
            .animation(Self.loopAnimation(for: state, mode: motionMode), value: motionPhase)
    }

    private var avatarCanvas: some View {
        ScienceAvatarCanvas(layers: ScienceAvatarGeometry.layers(for: shapeValue), palette: colors)
    }

    static func motionMode(for state: ScienceAvatarMotionState, animate: Bool, reduceMotion: Bool) -> ScienceAvatarMotionMode {
        guard animate, !reduceMotion else { return .static }
        return state == .done ? .finite : state == .idle ? .static : .looping
    }

    static let doneMotionDuration: TimeInterval = 0.8

    static func motionTransform(for state: ScienceAvatarMotionState, active: Bool, reduceMotion: Bool, phase: Bool) -> ScienceAvatarMotionTransform {
        guard active, !reduceMotion else { return .zero }
        switch state {
        case .idle, .done: return .zero
        case .thinking: return .init(scale: 1, rotation: phase ? 3 : -3, offsetY: 0)
        case .working: return .init(scale: phase ? 1.025 : 0.985, rotation: 0, offsetY: phase ? -2 : 0)
        case .sleeping: return .init(scale: phase ? 0.985 : 0.97, rotation: phase ? -3 : 3, offsetY: 2)
        }
    }

    private static func loopAnimation(for state: ScienceAvatarMotionState, mode: ScienceAvatarMotionMode) -> Animation? {
        guard mode == .looping else { return nil }
        return .easeInOut(duration: state == .working ? 1.1 : state == .sleeping ? 3.2 : 1.4).repeatForever(autoreverses: true)
    }
}

/// A static family mark for helper agents, using the parent's exact identity.
/// The three characters are a symbol; the adjacent label supplies the count.
struct ScienceAvatarGroup: View {
    let shape: ScienceAvatarShape
    let palette: ScienceAvatarPalette
    var size: CGFloat = 28

    var body: some View {
        ScienceAvatarCanvas(layers: ScienceAvatarGeometry.groupLayers(for: shape), palette: palette)
            .frame(width: 256, height: 256)
            .scaleEffect(size / 256)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel("\(shape.title) agents, \(palette.name) palette")
            .accessibilityAddTraits(.isImage)
    }
}

private struct ScienceAvatarCanvas: View {
    let layers: [ScienceAvatarVectorLayer]
    let palette: ScienceAvatarPalette

    var body: some View {
        Canvas { context, _ in
            for layer in layers {
                context.opacity = layer.opacity
                if layer.fill != nil {
                    context.fill(layer.path, with: .color(color(layer.fill)))
                }
                if layer.stroke != nil {
                    context.stroke(layer.path, with: .color(color(layer.stroke)), style: StrokeStyle(
                        lineWidth: layer.lineWidth, lineCap: layer.lineCap, lineJoin: layer.lineJoin))
                }
            }
        }
    }

    private func color(_ paint: ScienceAvatarPaint?) -> Color {
        switch paint {
        case .body: Color(hex: palette.body)
        case .shadow: Color(hex: palette.shadow)
        case .accent: Color(hex: palette.accent)
        case .ink: Color(hex: palette.ink)
        case nil: .clear
        }
    }
}

private struct DoneMotionValues {
    var scale: CGFloat = 1
    var rotation: Double = 0
    var offsetY: CGFloat = 0
}

enum ScienceAvatarPaint: Sendable { case body, shadow, accent, ink }

/// Immutable, precompiled geometry is shared by every avatar instance.
struct ScienceAvatarVectorLayer: Sendable {
    let path: Path
    let fill: ScienceAvatarPaint?
    let stroke: ScienceAvatarPaint?
    let lineWidth: CGFloat
    let lineCap: CGLineCap
    let lineJoin: CGLineJoin
    let opacity: Double
}

enum ScienceAvatarPresentation {
    static func shape(rawValue: String?, identity: String) -> ScienceAvatarShape {
        ScienceAvatarShape(rawValue: rawValue ?? "") ?? ScienceAvatarCatalog.stableShape(for: identity)
    }

    static func palette(rawValue: String?, legacyColor: String?) -> ScienceAvatarPalette {
        ScienceAvatarPalette.resolve(rawValue, legacyColor: legacyColor)
    }
}

/// Shared native picker used by Bot settings and the offline diagnostics fixture.
struct ScienceAvatarPicker: View {
    @Binding var shape: ScienceAvatarShape
    @Binding var paletteID: String
    @ScaledMetric(relativeTo: .caption) private var characterWidth = 68.0

    private var selectedPalette: ScienceAvatarPalette { ScienceAvatarPalette.resolve(paletteID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(ScienceAvatarCatalog.shapes) { candidate in
                        Button {
                            shape = candidate
                        } label: {
                            VStack(spacing: 4) {
                                ScienceAvatar(shape: candidate.rawValue, palette: selectedPalette.id, size: 58)
                                    .overlay(alignment: .topTrailing) {
                                        if shape == candidate {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 15, weight: .semibold))
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, Color.accentColor)
                                        }
                                    }
                                Text(candidate.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .frame(minWidth: characterWidth, minHeight: 82)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("science-avatar-shape-\(candidate.id)")
                        .accessibilityLabel("\(candidate.title) character, \(selectedPalette.name) palette")
                        .accessibilityValue(shape == candidate ? "Selected" : "Not selected")
                        .accessibilityAddTraits(shape == candidate ? [.isSelected] : [])
                        .id(candidate.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("science-avatar-character-row")
            .onAppear { proxy.scrollTo(shape.id, anchor: .center) }
            .onChange(of: shape) { _, selected in proxy.scrollTo(selected.id, anchor: .center) }
            }

            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ScienceAvatarCatalog.palettes) { candidate in
                        Button {
                            paletteID = candidate.id
                        } label: {
                            Circle()
                                .fill(Color(hex: candidate.body))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if paletteID == candidate.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(Color(hex: candidate.ink))
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("science-avatar-palette-\(candidate.id)")
                        .accessibilityLabel("\(candidate.name) color")
                        .accessibilityValue(paletteID == candidate.id ? "Selected" : "Not selected")
                        .accessibilityAddTraits(paletteID == candidate.id ? [.isSelected] : [])
                        .id(candidate.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("science-avatar-color-row")
            .onAppear { proxy.scrollTo(paletteID, anchor: .center) }
            .onChange(of: paletteID) { _, selected in proxy.scrollTo(selected, anchor: .center) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
