import Foundation
import SwiftUI
import Testing
@testable import wordrus

/// The curiosity lists ship as hand-written JSON: a typo in one entry would
/// silently drop the whole language's file, so every bundled language must
/// decode and every entry must carry what its card shows.
@MainActor
struct CuriosityTests {
    private static let languages: [TargetLanguage] = [.spanish, .french, .german, .italian]

    @Test(arguments: languages)
    func listDecodesWithCompleteEntries(_ language: TargetLanguage) {
        let items = CuriosityService.all(for: language)
        #expect(items.count >= 30)
        #expect(Set(items.map(\.id)).count == items.count)
        for item in items {
            #expect(item.id.hasPrefix(language.languageCode + "-"))
            switch item.kind {
            case .falseFriend: #expect(item.looksLike != nil, "\(item.id) needs looksLike")
            case .idiom, .literal: #expect(item.literal != nil, "\(item.id) needs literal")
            case .untranslatable: break
            }
        }
    }

    /// Set `CURIOSITY_RENDER_DIR` (as `TEST_RUNNER_CURIOSITY_RENDER_DIR` via
    /// xcodebuild) to write every share image there for a visual check.
    @Test func shareImagesRender() throws {
        let dir = ProcessInfo.processInfo.environment["CURIOSITY_RENDER_DIR"]
        for language in Self.languages {
            for item in CuriosityService.all(for: language) {
                let image = try #require(CuriosityShareImage.render(item, language: language))
                #expect(image.size == CGSize(width: 360, height: 640))
                if let dir, let png = image.pngData() {
                    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(item.id).png"))
                }
            }
        }
    }
}
