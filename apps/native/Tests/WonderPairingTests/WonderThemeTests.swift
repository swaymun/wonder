import XCTest
@testable import WonderPairing

final class WonderThemeTests: XCTestCase {
    private func palettes(_ spec: WonderThemeSpec) -> [(String, ThemePalette)] {
        [("light", spec.palette(systemIsDark: false)), ("dark", spec.palette(systemIsDark: true))]
            .filter { spec.scheme == .system || $0.0 == (spec.forcedDark == true ? "dark" : "light") }
    }

    func testCatalogHasWonderFirstAndUniqueIdsInTheExpectedRange() {
        let themes = WonderThemeCatalog.themes
        XCTAssertEqual(themes.first?.id, WonderThemeCatalog.defaultID)
        XCTAssertEqual(themes.first?.scheme, .system)
        XCTAssertEqual(Set(themes.map(\.id)).count, themes.count)
        XCTAssertEqual(Set(themes.map(\.name)).count, themes.count)
        XCTAssertTrue((16...26).contains(themes.count), "\(themes.count) themes")
        XCTAssertEqual(themes.filter { $0.background != nil }.count, 5)
    }

    func testUnknownStoredThemeFallsBackToWonder() {
        XCTAssertEqual(WonderThemeCatalog.theme(id: "retired-theme").id, "wonder")
        XCTAssertEqual(WonderThemeCatalog.theme(id: nil).id, "wonder")
        XCTAssertEqual(WonderThemeCatalog.theme(id: "nord").name, "Nord")
    }

    func testSchemesDeclareOnlyThePalettesTheyNeed() {
        for spec in WonderThemeCatalog.themes {
            switch spec.scheme {
            case .system: XCTAssertNil(spec.forcedDark); XCTAssertNotEqual(spec.palette(systemIsDark: true), spec.palette(systemIsDark: false), spec.id)
            case .dark: XCTAssertEqual(spec.forcedDark, true); XCTAssertEqual(spec.palette(systemIsDark: false), spec.palette(systemIsDark: true), spec.id)
            case .light: XCTAssertEqual(spec.forcedDark, false)
            }
        }
    }

    func testTextAndSyntaxKeepWCAGContrastOnEverySurface() {
        for spec in WonderThemeCatalog.themes {
            for (tag, p) in palettes(spec) {
                for (surface, color) in [("background", p.background), ("sidebar", p.sidebar), ("agent", p.agentBubble),
                                         ("user", p.userBubble), ("code", p.codeBackground)] {
                    XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.primaryText, color), 4.5, "\(spec.id) \(tag) text on \(surface)")
                }
                for (surface, color) in [("background", p.background), ("sidebar", p.sidebar), ("agent", p.agentBubble), ("code", p.codeBackground)] {
                    XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.secondaryText, color), 4.5, "\(spec.id) \(tag) secondary on \(surface)")
                }
                for role in [SyntaxRole.keyword, .string, .number, .comment, .type, .function, .punctuation] {
                    XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.color(for: role), p.codeBackground), 3.0, "\(spec.id) \(tag) \(role)")
                }
            }
        }
    }

    func testSidebarIsDistinctFromTheConversationBackground() {
        for spec in WonderThemeCatalog.themes {
            for (tag, p) in palettes(spec) {
                // Wonder's own sidebar measures 1.12 (dark) and 1.15 (light); every theme must stay at or above 1.10.
                XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(p.sidebar, p.background), 1.10, "\(spec.id) \(tag) sidebar vs background")
            }
        }
    }

    func testPhotoThemesKeepTextReadableOverTheirBrightestAndDarkestPixels() {
        for spec in WonderThemeCatalog.themes {
            guard let photo = spec.background else { continue }
            let p = spec.palette(systemIsDark: spec.forcedDark == true)
            XCTAssertTrue(photo.asset.hasPrefix("ThemeBackground"), spec.id)
            XCTAssertTrue((0.5...0.9).contains(photo.scrim), "\(spec.id) scrim")
            for pixel in [photo.pixelRange.lowerBound, photo.pixelRange.upperBound] {
                XCTAssertGreaterThanOrEqual(
                    ThemeContrast.worstCaseRatio(foreground: p.primaryText, scrimColor: p.background, scrim: photo.scrim, pixelValue: pixel),
                    4.5, "\(spec.id) text over pixel \(pixel)")
                XCTAssertGreaterThanOrEqual(
                    ThemeContrast.worstCaseRatio(foreground: p.secondaryText, scrimColor: p.background, scrim: photo.scrim, pixelValue: pixel),
                    4.5, "\(spec.id) secondary over pixel \(pixel)")
            }
        }
    }

    // Contract: a palette derived from another project names the themes it
    // covers, and those themes exist, so the notice in Acknowledgements stays true.
    func testDerivedPalettesCarryTheirNotice() {
        let ids = Set(WonderThemeCatalog.themes.map(\.id))
        for credit in ThemeCredits.all {
            XCTAssertFalse(credit.themeIDs.isEmpty, credit.title)
            XCTAssertTrue(Set(credit.themeIDs).isSubset(of: ids), credit.title)
            XCTAssertTrue(credit.license.contains("Permission is hereby granted"), credit.title)
        }
    }

    func testContrastRatioMatchesKnownValues() {
        XCTAssertEqual(ThemeContrast.ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(ThemeContrast.ratio(0x777777, 0xFFFFFF), 4.48, accuracy: 0.02)
    }
}
