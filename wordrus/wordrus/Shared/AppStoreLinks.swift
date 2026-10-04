import Foundation

/// Canonical App Store links for sharing the app and leaving a review.
///
/// Every app in App Store Connect is assigned a numeric Apple ID as soon as
/// the record is created — even before the first release is approved. Fill in
/// `appleID` below with that value (App Store Connect → App → App Information →
/// "Apple ID"). The Share and Leave-a-Review entries in Settings both build
/// their URLs from it.
enum AppStoreLinks {
    /// The app's numeric App Store Apple ID. TODO: replace with the real ID.
    static let appleID = "0000000000"

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
