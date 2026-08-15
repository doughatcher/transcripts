import Foundation
import TranscriptsCore

/// Checks GitHub Releases for a newer Transcripts and downloads the zipped app.
///
/// Points at a **public releases repo**, deliberately not at the source repo,
/// which is private. Private repos do not serve release assets without
/// credentials, and shipping a freeware Mac app that first demands the user
/// mint a GitHub token is not a thing anyone should have to do — that is
/// precisely the machinery this replaces.
///
/// Splitting the channel from the source also deletes an entire category of
/// failure. Against a private repo GitHub answers 404 both for "no such
/// release" and for "your token may not know this repo exists", so the ancestor
/// had to probe a second endpoint to tell a missing release from a missing
/// permission. Unauthenticated against a public repo, a 404 means what it says.
///
/// The same public URLs back the Homebrew cask, so `brew upgrade` and the
/// in-app updater are two doors onto one artifact rather than two release
/// processes that can drift.
///
/// The one cost of being unauthenticated is GitHub's 60-requests-per-hour
/// per-IP limit — which one update check will never approach on its own, but
/// which a shared office egress IP can exhaust, so it is reported as itself
/// rather than as a generic HTTP error.
enum Updater {
    static let repo = "hatcher-ltd/transcripts-releases"

    struct Release {
        let version: String        // normalized, e.g. "0.2.0"
        let tag: String            // e.g. "v0.2.0"
        let notes: String?
        let assetURL: URL?         // public browser_download_url
        let assetName: String?
    }

    enum UpdateError: LocalizedError {
        case http(Int)
        case noAsset
        case badResponse
        /// GitHub's unauthenticated rate limit, shared across everyone on this IP.
        case rateLimited
        /// The repo is reachable but has no published stable release.
        case noStableRelease

        var errorDescription: String? {
            switch self {
            case .http(let c):
                return "GitHub returned HTTP \(c)."
            case .noAsset:
                return "The latest release has no downloadable app asset."
            case .badResponse:
                return "Unexpected response from GitHub."
            case .rateLimited:
                return "GitHub is rate-limiting update checks from this network. Try again in a little while."
            case .noStableRelease:
                return "There's no stable release published yet — only pre-releases. Turn on \"Ride the beta train\" above to get those."
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Check

    /// The newest applicable release. Stable riders get GitHub's
    /// `releases/latest` (which excludes pre-releases by definition); the beta
    /// train lists recent releases and picks the highest version, pre-release
    /// or not. Non-app releases are filtered by requiring a `v`-prefixed tag.
    static func latest(includePrereleases: Bool = false) async throws -> Release {
        let path = includePrereleases ? "releases?per_page=15" : "releases/latest"

        let (data, http) = try await get(path)
        guard (200...299).contains(http.statusCode) else {
            // `releases/latest` 404s when every release is a pre-release — the
            // only 404 a public repo can produce here.
            if http.statusCode == 404, !includePrereleases { throw UpdateError.noStableRelease }
            if http.statusCode == 403, isRateLimited(http) { throw UpdateError.rateLimited }
            throw UpdateError.http(http.statusCode)
        }

        let obj: [String: Any]?
        if includePrereleases {
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw UpdateError.badResponse
            }
            obj = list
                .filter { ($0["draft"] as? Bool) != true }
                .filter { (($0["tag_name"] as? String) ?? "").hasPrefix("v") }
                .max { a, b in
                    AppVersion.compare((a["tag_name"] as? String) ?? "0",
                                       (b["tag_name"] as? String) ?? "0") < 0
                }
        } else {
            obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let obj, let tag = obj["tag_name"] as? String else { throw UpdateError.badResponse }

        // Pick the asset matching THIS release's version (tested in
        // AppVersion.assetName) — never just the first zip, which once installed an
        // ancient build in a silent downgrade loop.
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let names = assets.compactMap { $0["name"] as? String }
        let chosenName = AppVersion.assetName(from: names, version: normalize(tag))
        let zip = assets.first { ($0["name"] as? String) == chosenName }
        // browser_download_url, not the API asset url: public assets download
        // straight from it with no Accept header and no credentials.
        let assetURL = (zip?["browser_download_url"] as? String).flatMap(URL.init(string:))

        return Release(
            version: normalize(tag),
            tag: tag,
            notes: obj["body"] as? String,
            assetURL: assetURL,
            assetName: zip?["name"] as? String)
    }

    /// True when `remote` is a higher version than the running app.
    static func isNewer(_ remote: String) -> Bool { compare(remote, currentVersion) > 0 }

    // MARK: - Transport

    private static func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let base = "https://api.github.com/repos/\(repo)"
        var req = URLRequest(url: URL(string: path.isEmpty ? base : "\(base)/\(path)")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.badResponse }
        return (data, http)
    }

    /// GitHub signals an exhausted quota as 403 with the remaining count at zero,
    /// which is otherwise indistinguishable from an ordinary refusal.
    private static func isRateLimited(_ http: HTTPURLResponse) -> Bool {
        http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
    }

    // MARK: - Download

    /// Downloads the release asset to a temp file (the returned URL is a `.zip`).
    static func download(_ release: Release) async throws -> URL {
        guard let assetURL = release.assetURL else { throw UpdateError.noAsset }
        let (tmp, resp) = try await URLSession.shared.download(from: assetURL)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(release.assetName ?? "Transcripts-\(release.version).zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: - Version compare (pre-release-aware; logic tested in TranscriptsCore)

    static func normalize(_ tag: String) -> String { AppVersion.normalize(tag) }
    static func compare(_ a: String, _ b: String) -> Int { AppVersion.compare(a, b) }
}
