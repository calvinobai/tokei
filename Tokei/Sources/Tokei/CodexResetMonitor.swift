import Foundation
import Combine

final class CodexResetMonitor: ObservableObject {
    static let shared = CodexResetMonitor()
    static let enabledKey = "codexResetAnnouncementsEnabled"
    static let pageURL = URL(string: "https://aihot.news/codex-reset")!
    static let feedURL = URL(string: "https://aihot.news/api/site/codex-reset")!
    static let refreshInterval: TimeInterval = 10 * 60

    struct Snapshot: Codable {
        let feed: CodexResetFeed
        let fetchedAt: Date
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastFetchFailed = false
    private var lastAttempt = Date.distantPast
    private var requestTask: URLSessionDataTask?
    private var requestID: UUID?
    private let session: URLSession
    private let cacheURL: URL?

    init(session: URLSession? = nil, cacheURL: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tokei/codex_reset_announcements.json")) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: config)
        self.cacheURL = cacheURL
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), data.count <= 1_000_000,
           let cached = try? JSONDecoder().decode(Snapshot.self, from: data),
           (try? cached.feed.validate()) != nil {
            snapshot = cached
        }
    }

    func refresh(enabled: Bool = UserDefaults.standard.bool(forKey: enabledKey),
                 force: Bool = false, now: Date = Date()) {
        guard enabled else {
            if requestTask != nil { lastAttempt = .distantPast }
            requestID = nil
            requestTask?.cancel()
            requestTask = nil
            isRefreshing = false
            return
        }
        // Manual retries are bounded too; regular collector ticks never cause extra traffic.
        let interval: TimeInterval = force ? 30 : Self.refreshInterval
        guard !isRefreshing, now.timeIntervalSince(lastAttempt) >= interval else { return }
        lastAttempt = now
        isRefreshing = true
        let id = UUID()
        requestID = id
        var request = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The site's edge rejects clients without a browser-compatible User-Agent.
        request.setValue("Mozilla/5.0 (Macintosh) Tokei", forHTTPHeaderField: "User-Agent")
        requestTask = session.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<CodexResetFeed, Error> = Result {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse,
                      response.statusCode == 200, response.url?.host == Self.feedURL.host,
                      response.url?.scheme == "https",
                      response.mimeType == "application/json",
                      let data, data.count <= 1_000_000 else {
                    throw CodexResetFeed.FeedError.invalidResponse
                }
                return try CodexResetFeed.decode(data)
            }
            DispatchQueue.main.async {
                guard let self, self.requestID == id else { return }
                self.requestTask = nil
                self.requestID = nil
                self.isRefreshing = false
                switch result {
                case .success(let feed):
                    let snapshot = Snapshot(feed: feed, fetchedAt: Date())
                    self.snapshot = snapshot
                    self.lastFetchFailed = false
                    if let cacheURL = self.cacheURL, let data = try? JSONEncoder().encode(snapshot) {
                        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                               withIntermediateDirectories: true)
                        try? data.write(to: cacheURL, options: .atomic)
                    }
                case .failure:
                    self.lastFetchFailed = true
                }
            }
        }
        requestTask?.resume()
    }

    /// Deterministic offscreen previews; does not write cache or start networking.
    func usePreview(_ feed: CodexResetFeed, at now: Date = Date()) {
        snapshot = Snapshot(feed: feed, fetchedAt: now)
        lastFetchFailed = false
    }
}
