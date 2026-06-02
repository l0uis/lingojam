import Foundation

enum AppGroup {
    static let identifier = "group.com.louiscurrie.wordrus"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}
