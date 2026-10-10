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
    /// A plain screen or sheet: the system background on the default theme.
    var page: Color { isDefault ? Color(uiColor: .systemBackground) : background }
    /// Body text on the page, for SwiftUI and for UIKit text views.
    var text: Color { isDefault ? Color.primary : primaryText }
    var textUIColor: UIColor { isDefault ? .label : UIColor(hex: palette.primaryText) }
    /// Small chips and choices that sit on a surface or the page.
    var chip: Color { isDefault ? Color(uiColor: .tertiarySystemBackground) : surface }
    /// Hairlines between columns, such as a split diff's.
    var rule: Color { isDefault ? Color(uiColor: .separator) : separator }

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
    @AppStorage(WonderTypography.messageKey) private var messageFontID = MessageFont.system.rawValue
    @AppStorage(WonderTypography.codeKey) private var codeFontID = CodeFont.system.rawValue
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let theme = WonderTheme.resolve(id: ProcessInfo.processInfo.diagnosticThemeOverride ?? themeID,
                                        systemIsDark: systemScheme == .dark)
        return content
            .onChange(of: theme.spec, initial: true) { _, spec in SyntaxColors.activate(spec) }
            .environment(\.wonderTheme, theme)
            .environment(\.wonderTypography, WonderTypography(
                messageID: ProcessInfo.processInfo.diagnosticFontOverride ?? messageFontID,
                codeID: ProcessInfo.processInfo.diagnosticCodeFontOverride ?? codeFontID))
            .preferredColorScheme(theme.forcedScheme)
            // Actions read as plain text, not blue links; the default theme keeps `.primary`.
            .tint(theme.isDefault ? Color.primary : theme.primaryText)
            .containerBackground(theme.isDefault ? Color(uiColor: .systemBackground) : theme.background, for: .navigation)
    }
}

/// The filled primary button. Themes tint controls with their text colour, and
/// `.borderedProminent` fills with the tint and labels in white, so on a dark
/// theme the label vanished into its fill. The label takes the theme's
/// background instead; the Wonder theme keeps the system style.
struct WonderProminentButtonStyle: PrimitiveButtonStyle {
    @Environment(\.wonderTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            if theme.isDefault { configuration.label }
            else { configuration.label.foregroundStyle(theme.background) }
        }
        .buttonStyle(.borderedProminent) // theme-exempt: the one owner of the prominent style
    }
}

extension PrimitiveButtonStyle where Self == WonderProminentButtonStyle {
    static var wonderProminent: WonderProminentButtonStyle { WonderProminentButtonStyle() }
}

/// Settings-style Lists and Forms: on a non-default theme the page takes the theme's
/// background and rows sit on its surface colour. The Wonder theme keeps the system
/// grouped look. One owner, applied once per screen, never per row. `overBackdrop`
/// leaves the page clear for a list drawn over the conversation's own backdrop.
private struct WonderGroupedStyle: ViewModifier {
    @Environment(\.wonderTheme) private var theme
    let overBackdrop: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if theme.isDefault {
            content
        } else {
            content
                .scrollContentBackground(.hidden)
                .background(overBackdrop ? Color.clear : theme.background)
                .listRowBackground(theme.surface)
        }
    }
}

/// A screen or sheet that is not a grouped List: the theme's page (with its photo)
/// behind it, under the navigation bar and behind a presented sheet, and the theme's
/// text colour. The Wonder theme keeps the system look.
private struct WonderPage: ViewModifier {
    @Environment(\.wonderTheme) private var theme

    @ViewBuilder func body(content: Content) -> some View {
        if theme.isDefault {
            content
        } else {
            content
                .foregroundStyle(theme.primaryText)
                .containerBackground(for: .navigation) { ThemeBackdrop() }
                .presentationBackground { ThemeBackdrop() }
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
    func wonderGroupedStyle(overBackdrop: Bool = false) -> some View {
        modifier(WonderGroupedStyle(overBackdrop: overBackdrop))
    }
    func wonderPage() -> some View { modifier(WonderPage()) }
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
    /// `-diagnostics-font MESSAGE[+CODE]` forces the faces, for example `serif+jetBrains`.
    var diagnosticFontOverride: String? { diagnosticFonts?.first }
    var diagnosticCodeFontOverride: String? { diagnosticFonts.flatMap { $0.count > 1 ? $0[1] : nil } }
    private var diagnosticFonts: [String]? {
        #if WONDER_DIAGNOSTICS
        DiagnosticTheme.value(after: "-diagnostics-font").map { $0.split(separator: "+").map(String.init) }
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

/// The composer and its pills belong to the chat: they draw nothing of their own, so the
/// theme's background or photo shows through. With Reduce Transparency on they take the
/// solid chat background instead, so a photo never sits behind their text.
struct ChatBottomUnit: ViewModifier {
    @Environment(\.wonderTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background(reduceTransparency
            ? (theme.isDefault ? Color(uiColor: .systemBackground) : theme.background)
            : Color.clear)
    }
}

/// Lets the timeline fade out over its last few points instead of ending in a hard edge
/// above the composer. A mask keeps layout, scroll geometry and the backdrop untouched;
/// shorter than the timeline's bottom margin, so the last message is never dimmed.
/// With Reduce Transparency on, the composer is solid and the timeline simply ends.
struct TimelineBottomFade: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let enabled: Bool

    func body(content: Content) -> some View {
        // Always masked, so toggling never rebuilds the timeline's identity.
        content.mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: enabled && !reduceTransparency ? 14 : 0)
            }
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
