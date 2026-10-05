import Foundation
import Testing
@testable import OjoApp

/// The popover's type scale lives in Theme.swift (Ojo.Style). macOS text styles are
/// small (.subheadline is 11 pt, .caption 10 pt), which made the text look tiny beside
/// full-size buttons and switches. The main screens must use the scale, not styles.
@Test func mainScreensUseTheOjoTypeScale() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let views = root.appendingPathComponent("Sources/Views")
    let screens = ["StatusHeroView.swift", "RoomView.swift", "MenuContentView.swift", "Theme.swift"]
    let forbidden = #"\.font\(\.(caption2?|footnote|subheadline|callout|headline|title[23]?|body)\)"#
    for name in screens {
        let source = try String(contentsOf: views.appendingPathComponent(name), encoding: .utf8)
        #expect(source.range(of: forbidden, options: .regularExpression) == nil,
                "\(name) uses a system text style; use Ojo.Style (see CamTuneApp/DESIGN.md)")
        #expect(source.range(of: "design: .rounded", options: .literal) == nil,
                "\(name) mixes in a rounded typeface; the app uses one typeface (SF Pro)")
    }
}
