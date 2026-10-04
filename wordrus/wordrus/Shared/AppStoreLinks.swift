import Foundation

/// Canonical App Store links for sharing the app and leaving a review.
///
/// `appleID` is the app's numeric Apple ID (App Store Connect → App → App
/// Information → "Apple ID"). The Share and Leave-a-Review entries in Settings
/// and on the deck's end-of-day card all build their URLs from it.
enum AppStoreLinks {
    /// The app's numeric App Store Apple ID.
    static let appleID = "6775888601"

    /// AppStorage key set once the user has opened the "Write a Review" page,
    /// so the deck's end-of-day card stops asking. We can't see whether they
    /// actually posted one — opening it is the best signal available.
    static let didOpenWriteReviewKey = "appStore.didOpenWriteReview"

    /// Public App Store product page — used as the shareable link.
    static var productURL: URL {
        URL(string: "https://apps.apple.com/app/id\(appleID)")!
    }

    /// Deep link that opens the App Store straight to the "Write a Review"
    /// composer for this app.
    static var writeReviewURL: URL {
        URL(string: "https://apps.apple.com/app/id\(appleID)?action=write-review")!
    }
}
