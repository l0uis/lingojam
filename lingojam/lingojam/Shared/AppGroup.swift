import Foundation

enum AppGroup {
    static let identifier = "group.com.louiscurrie.lingojam"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}
