import Foundation

/// Single source of truth for the walrus proxy URL. Hardcoded rather
/// than user-configurable — every install hits the same Worker.
///
/// The URL isn't actually a secret: the proxy's auth lives in its
/// bundle-ID check + per-device rate limit, not in URL obscurity.
enum WalrusProxyConfig {
    static let proxyURL: String = "https://walrus-proxy.currielouis.workers.dev"
}
