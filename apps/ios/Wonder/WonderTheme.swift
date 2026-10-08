import ImageIO
import SwiftUI
import UIKit
import WonderPairing

/// The one owner of Wonder's colours: a theme from `WonderThemeCatalog`
/// resolved for one appearance. It is a small static value injected through the
/// environment by `WonderThemeHost`; views read tokens and never compute colours
/// per row.
struct WonderTheme: Equatable {
    static let storageKey = "wonderThemeID"

    let spec: WonderThemeSpec
    let isDark: Bool
    let palette: ThemePalette

    init(spec: WonderThemeSpec, systemIsDark: Bool) {
        self.spec = spec
        palette = spec.palette(systemIsDark: systemIsDark)
        isDark = spec.forcedDark ?? systemIsDark
    }

    static func resolve(id: String?, systemIsDark: Bool) -> WonderTheme {
        WonderTheme(spec: WonderThemeCatalog.theme(id: id), systemIsDark: systemIsDark)
    }

    var id: String { spec.id }
    /// The default theme keeps iOS's own tint and bubble-palette choices.
    var isDefault: Bool { spec.id == WonderThemeCatalog.defaultID }
    var photo: ThemeBackground? { spec.background }
    var forcedScheme: ColorScheme? { spec.forcedDark.map { $0 ? .dark : .light } }
    var cacheKey: String { "\(spec.id)-\(isDark ? "d" : "l")" }

    var background: Color { Color(hex: palette.background) }
    var sidebar: Color { Color(hex: palette.sidebar) }
    var primaryText: Color { Color(hex: palette.primaryText) }
    var secondaryText: Color { Color(hex: palette.secondaryText) }
    var separator: Color { Color(hex: palette.separator) }
    var accent: Color { Color(hex: palette.accent) }
    var codeBackground: Color { Color(hex: palette.codeBackground) }
    /// A search field on the sidebar: lighter than the sidebar in dark, white-ish in light.
    var field: Color { Color(hex: isDark ? palette.agentBubble : palette.background) }
    /// The composer and navigation bar; slightly see-through over a photo.
    var chrome: Color { photo == nil ? background : background.opacity(0.9) }

    /// Controls that sit on the page, such as the composer and its pills: the system
    /// fill on the default theme, the agent bubble's colour on any other.
    var surface: Color { isDefault ? Color(uiColor: .secondarySystemBackground) : Color(hex: palette.agentBubble) }

    func bubble(isUser: Bool) -> Color {
        Color(hex: isUser ? palette.userBubble : palette.agentBubble).opacity(photo == nil ? 1 : 0.92)
    }
    func syntax(_ role: SyntaxRole) -> Color { Color(hex: palette.color(for: role)) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

private struct WonderThemeKey: EnvironmentKey {
    static let defaultValue = WonderTheme.resolve(id: nil, systemIsDark: false)
}

extension EnvironmentValues {
    var wonderTheme: WonderTheme {
        get { self[WonderThemeKey.self] }
        set { self[WonderThemeKey.self] = newValue }
    }
}

/// Injects the chosen theme and applies what must follow it app-wide: the
/// forced appearance, the tint and the navigation background.
struct WonderThemeHost: ViewModifier {
    @AppStorage(WonderTheme.storageKey) private var themeID = WonderThemeCatalog.defaultID
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let theme = WonderTheme.resolve(id: ProcessInfo.processInfo.diagnosticThemeOverride ?? themeID,
                                        systemIsDark: systemScheme == .dark)
        return content
            .onChange(of: theme.spec, initial: true) { _, spec in SyntaxColors.activate(spec) }
            .environment(\.wonderTheme, theme)
            .preferredColorScheme(theme.forcedScheme)
            // Actions read as plain text, not blue links; the default theme keeps `.primary`.
            .tint(theme.isDefault ? Color.primary : theme.primaryText)
            .containerBackground(theme.isDefault ? Color(uiColor: .systemBackground) : theme.background, for: .navigation)
    }
}

/// Settings-style Lists and Forms: on a non-default theme the page takes the theme's
/// background and rows sit on its surface colour. The Wonder theme keeps the system
/// grouped look. One owner, applied once per screen, never per row.
private struct WonderGroupedStyle: ViewModifier {
    @Environment(\.wonderTheme) private var theme

    @ViewBuilder func body(content: Content) -> some View {
        if theme.isDefault {
            content
        } else {
            content
                .scrollContentBackground(.hidden)
                .background(theme.background)
                .listRowBackground(theme.surface)
        }
    }
}

/// A sheet's title and Done button that stay put. On a short screen (the iPhone Duo) the
/// navigation bar of a scrolled sheet slides away with its Done button, so the header is
/// a fixed inset instead. Inside a NavigationStack; the system bar is hidden.
private struct PinnedSheetHeader: ViewModifier {
    @Environment(\.wonderTheme) private var theme
    let title: String
    let onDone: () -> Void

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Done", action: onDone).fontWeight(.semibold).frame(minHeight: 44)
                        .accessibilityIdentifier("sheet-done")
                }
                .padding(.horizontal, 20).padding(.top, 8)
                .background(theme.isDefault ? AnyShapeStyle(.bar) : AnyShapeStyle(theme.background))
            }
    }
}

extension View {
    func pinnedSheetHeader(_ title: String, onDone: @escaping () -> Void) -> some View {
        modifier(PinnedSheetHeader(title: title, onDone: onDone))
    }
    func wonderGroupedStyle() -> some View { modifier(WonderGroupedStyle()) }
}

extension ProcessInfo {
    /// `-diagnostics-theme <id>` forces a theme so screens can be captured.
    var diagnosticThemeOverride: String? {
        #if WONDER_DIAGNOSTICS
        DiagnosticTheme.forcedID
        #else
        nil
        #endif
    }
}

/// Syntax colours for diffs, whose attributed text is prepared once off the
/// main thread. The colours resolve at draw time from the active theme, so a
/// theme change recolours them without re-preparing the diff.
enum SyntaxColors {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active = WonderThemeCatalog.theme(id: nil)

    static func activate(_ spec: WonderThemeSpec) {
        lock.lock(); defer { lock.unlock() }
        if active != spec { active = spec }
    }

    static func color(_ role: SyntaxRole) -> Color {
        Color(uiColor: UIColor { traits in
            lock.lock(); let spec = active; lock.unlock()
            let hex = spec.palette(systemIsDark: traits.userInterfaceStyle == .dark).color(for: role)
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: Background photo

/// Draws a photo theme's picture once behind the conversation, under a flat
/// scrim. It is a background, so it never affects layout, and it draws only the
/// scrim colour when Reduce Transparency is on or the theme has no photo.
struct ThemeBackdrop: View {
    @Environment(\.wonderTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if theme.isDefault {
            Color.clear
        } else {
            ZStack {
                theme.background
                if let photo = theme.photo, !reduceTransparency {
                    ThemePhoto(asset: photo.asset)
                    theme.background.opacity(photo.scrim)
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
    }
}

private struct ThemePhoto: View {
    let asset: String
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .task(id: asset) { image = await ThemePhotoCache.shared.image(asset) }
    }
}

/// Decodes theme photos off the main thread at a bounded size and keeps at
/// most two, dropping them on memory pressure.
final class ThemePhotoCache: @unchecked Sendable {
    static let shared = ThemePhotoCache()
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 2; return cache
    }()

    func image(_ asset: String) async -> UIImage? {
        if let hit = cache.object(forKey: asset as NSString) { return hit }
        let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = NSDataAsset(name: asset)?.data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1536,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
        if let decoded { cache.setObject(decoded, forKey: asset as NSString) }
        return decoded
    }
}

// MARK: Settings

/// Settings → Appearance → Theme: one row per theme with a live swatch.
struct ThemePickerView: View {
    @AppStorage(WonderTheme.storageKey) private var themeID = WonderThemeCatalog.defaultID
    @Environment(\.colorScheme) private var systemScheme

    private var groups: [(title: String, themes: [WonderThemeSpec])] {
        let all = WonderThemeCatalog.themes
        return [("Wonder", all.filter { $0.id == WonderThemeCatalog.defaultID }),
                ("Classic", all.filter { $0.id != WonderThemeCatalog.defaultID && $0.background == nil }),
                ("Photo", all.filter { $0.background != nil })]
    }

    var body: some View {
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.themes) { spec in row(spec) }
                }
            }
        }
        .wonderGroupedStyle()
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("theme-picker")
    }

    private func row(_ spec: WonderThemeSpec) -> some View {
        // A Diagnostics build can force a theme; show the one actually in use.
        let selected = WonderThemeCatalog.theme(id: ProcessInfo.processInfo.diagnosticThemeOverride ?? themeID).id == spec.id
        return Button { themeID = spec.id } label: {
            HStack(spacing: 12) {
                ThemeSwatch(theme: WonderTheme(spec: spec, systemIsDark: systemScheme == .dark))
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name).foregroundStyle(.primary)
                    Text(detail(spec)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark").foregroundStyle(.tint).opacity(selected ? 1 : 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("theme-option:\(spec.id)")
    }

    private func detail(_ spec: WonderThemeSpec) -> String {
        switch spec.scheme {
        case .system: "Follows your device"
        case .dark: spec.background == nil ? "Dark" : "Dark photo"
        case .light: spec.background == nil ? "Light" : "Light photo"
        }
    }
}

/// A miniature conversation in a theme's colours: surface, sidebar edge, two
/// bubbles and the syntax palette.
struct ThemeSwatch: View {
    let theme: WonderTheme

    var body: some View {
        HStack(spacing: 0) {
            theme.sidebar.frame(width: 10)
            VStack(alignment: .leading, spacing: 4) {
                bubble(theme.bubble(isUser: false), width: 34, alignment: .leading)
                bubble(theme.bubble(isUser: true), width: 26, alignment: .trailing)
                HStack(spacing: 2) {
                    ForEach([SyntaxRole.keyword, .string, .number, .type, .function], id: \.self) { role in
                        Circle().fill(theme.syntax(role)).frame(width: 5, height: 5)
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.background)
        }
        .frame(width: 64, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.separator, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func bubble(_ color: Color, width: CGFloat, alignment: Alignment) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: width, height: 7)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}
