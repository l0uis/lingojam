import Foundation

enum DeepLink {
    static let pendingWordIDKey = "lingojam.pendingWordID"

    static var pendingWordID: String? {
        let value = UserDefaults.standard.string(forKey: pendingWordIDKey)
        return (value?.isEmpty == false) ? value : nil
    }

    static func consumePendingWordID() -> String? {
        let id = pendingWordID
        UserDefaults.standard.removeObject(forKey: pendingWordIDKey)
        return id
    }
}
