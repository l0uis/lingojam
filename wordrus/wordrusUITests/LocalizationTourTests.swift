import XCTest

/// Walks onboarding and the main screens in every shipped UI language and
/// saves a screenshot of each step, so translations and long-string layout
/// can be reviewed side by side without driving the simulator by hand.
///
/// Run one language (or all, when TOUR_LANGUAGES is unset):
///
///     TEST_RUNNER_TOUR_DIR=/tmp/tour TEST_RUNNER_TOUR_LANGUAGES=de \
///     xcodebuild test -project wordrus.xcodeproj -scheme wordrus \
///       -destination 'platform=iOS Simulator,name=iPhone 16e' \
///       -only-testing:wordrusUITests/LocalizationTourTests
///
/// Screenshots land in $TOUR_DIR/<lang>/NN-<label>.png and are also attached
/// to the test result. The walk is label-agnostic (it can't know the button
/// text in each language): it fills empty text fields, presses the
/// bottom-most wide button when enabled, and otherwise picks the first
/// option on screen.
final class LocalizationTourTests: XCTestCase {
    private let defaultLanguages = ["en", "es", "fr", "it", "de"]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testTourAllLanguages() throws {
        let env = ProcessInfo.processInfo.environment
        let languages = env["TOUR_LANGUAGES"]?.split(separator: ",").map(String.init) ?? defaultLanguages
        let outputRoot = env["TOUR_DIR"].map(URL.init(fileURLWithPath:))
        for language in languages {
            tour(language: language, outputRoot: outputRoot)
        }
    }

    @MainActor
    private func tour(language: String, outputRoot: URL?) {
        let app = XCUIApplication()
        let region = ["en": "GB", "es": "ES", "fr": "FR", "it": "IT", "de": "DE"][language] ?? "GB"
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", "\(language)_\(region)",
            "-uiResetOnboarding",
        ]
        app.launch()

        // System permission prompts are in the simulator's language, not the
        // app's — dismiss them whatever they say.
        let monitor = addUIInterruptionMonitor(withDescription: "system alert") { alert in
            let buttons = alert.buttons.allElementsBoundByIndex
            (buttons.last ?? alert.buttons.firstMatch).tap()
            return true
        }
        defer { removeUIInterruptionMonitor(monitor) }

        var step = 0
        func snap(_ label: String) {
            step += 1
            let shot = XCUIScreen.main.screenshot()
            let name = String(format: "%02d-%@", step, label)
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(language)/\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let root = outputRoot {
                let dir = root.appendingPathComponent(language, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }

        let window = app.windows.firstMatch
        _ = window.waitForExistence(timeout: 10)
        sleep(2)

        // Onboarding: at most 30 screens; stop once it's dismissed or the
        // screen stops changing.
        let onboarding = app.otherElements["onboarding"]
        var lastTree = ""
        var stuck = 0
        for _ in 0..<30 {
            guard onboarding.exists else { break }
            snap("onboarding")
            let tree = onboarding.debugDescription
            stuck = tree == lastTree ? stuck + 1 : 0
            lastTree = tree
            if stuck >= 2 { break }

            let field = onboarding.textFields.firstMatch
            if field.exists, (field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue {
                field.tap()
                field.typeText("Lena")
                app.swipeDown() // dismiss the keyboard so the primary button is reachable
            }

            guard let primary = bottomPrimaryButton(in: onboarding, window: window) else { break }
            if !primary.isEnabled, let option = firstOption(in: onboarding, window: window, above: primary) {
                option.tap()
            }
            if primary.isEnabled {
                primary.tap()
            } else {
                // Nothing selectable unlocked it — try the next-best button.
                app.tap() // lets an interruption monitor fire if an alert is up
            }
            sleep(1)
        }

        // The app asks for a rating right after onboarding. The prompt is a
        // remote view in the simulator's language; its last button dismisses.
        sleep(2)
        dismissReviewPrompt(app)

        // Main screens: the tab bar is a custom floating bar along the bottom.
        let frame = window.frame
        for (index, x) in [0.28, 0.5, 0.72].enumerated() {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.94)).tap()
            sleep(2)
            snap("tab\(index + 1)")
        }
        // Settings lives behind the gear at the top-right of the Phone tab.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.08)).tap()
        sleep(2)
        snap("settings")
        window.swipeUp()
        sleep(1)
        snap("settings-bottom")
        _ = frame
        app.terminate()

        // Paywall, via the DEBUG preview scene with a faked trial plan — no
        // store involved, so nothing can be bought.
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", "\(language)_\(region)",
            "-uiPreviewPaywall", "-uiPreviewTrial",
        ]
        app.launch()
        sleep(3)
        snap("paywall")
        app.windows.firstMatch.swipeUp()
        sleep(1)
        snap("paywall-bottom")
        app.terminate()
    }

    /// Closes the StoreKit rating prompt if it's up ("Not Now" in the
    /// simulator's language, so match the button shapes, not the label).
    @MainActor
    private func dismissReviewPrompt(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for source in [app, springboard] {
            let notNow = source.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 2) {
                notNow.tap()
                sleep(1)
                return
            }
        }
    }

    /// The bottom-most button spanning most of the width — the onboarding
    /// "Continue"/"Start" button in every step.
    @MainActor
    private func bottomPrimaryButton(in root: XCUIElement, window: XCUIElement) -> XCUIElement? {
        let width = window.frame.width
        return root.buttons.allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable && $0.frame.width > width * 0.6 }
            .max { $0.frame.midY < $1.frame.midY }
    }

    /// First tappable option between the top bar and the primary button.
    @MainActor
    private func firstOption(in root: XCUIElement, window: XCUIElement, above primary: XCUIElement) -> XCUIElement? {
        let top = window.frame.height * 0.15
        return root.buttons.allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable && $0.frame.minY > top && $0.frame.maxY < primary.frame.minY && $0.frame.width > 44 }
            .min { $0.frame.minY < $1.frame.minY }
    }
}
