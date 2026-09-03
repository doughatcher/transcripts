import CryptoKit
import Foundation
import TranscriptsCore

/// Checks for a newer Transcripts and downloads it.
///
/// Reads a small JSON manifest from the site rather than a code-hosting API.
/// The same file backs the Homebrew cask and the download button, so a release
/// cannot half-ship with brew offering one version and the app another — there
/// is one artifact and one description of it.
///
/// This replaced a GitHub Releases implementation twice over, and both
/// rewrites removed something rather than adding it. Against a *private* repo
/// the app needed a token, and a 404 meant either "no such release" or "your
/// token cannot see this repo" with no way to tell them apart. Against a public
/// repo the token went but the unauthenticated rate limit arrived. A static
/// file on the site we already publish has neither problem, and no API to be
/// deprecated underneath us.
///
/// The manifest carries the artifact's SHA-256, so unlike either predecessor
/// this one can verify what it downloaded before handing it to the installer.
enum Updater {
    /// Where the manifests live. Baked into every shipped build, so an installed
    /// copy checks *this* host forever — it is not a URL to move casually.
    static let baseURL = "https://transcripts.doughatcher.com"

    /// Stable and pre-release channels are separate files. A stable release
    /// writes both, so someone riding the beta train still gets a finished
    /// version when it is newer than the last beta.
    static func manifestURL(prereleases: Bool) -> URL {
        let name = prereleases ? "appcast-beta.json" : "appcast.json"
        // Cache-busted at the URL, not just with a header. A CDN edge kept
        // answering 200 for a manifest that had been removed, long after the
        // deployment that removed it — and a stale manifest is how someone gets
        // offered a build that is no longer the right one for their channel.
        // URLRequest.cachePolicy only governs the local cache; this defeats the
        // intermediary too.
        return URL(string: "\(baseURL)/\(name)?v=\(Int(Date().timeIntervalSince1970))")!
    }

    struct Release: Decodable {
        let version: String
        let url: URL
        let sha256: String
        let size: Int
        let notes: String?

        /// Kept so existing call sites read unchanged.
        var assetName: String? { url.lastPathComponent }
    }

    enum UpdateError: LocalizedError {
        case http(Int)
        case badResponse
        case noChannel(prerelease: Bool)
        /// The download did not match the manifest's digest.
        case checksumMismatch(expected: String, got: String)

        var errorDescription: String? {
            switch self {
            case .http(let c):
                return "Update check failed (HTTP \(c))."
            case .badResponse:
                return "The update manifest could not be read."
            case .noChannel(let prerelease):
                return prerelease
                    ? "There's no pre-release build published right now. Turn off \"Ride the beta train\" to follow stable releases."
                    : "There's no stable release published right now. Turn on \"Ride the beta train\" above to receive pre-release builds."
            case .checksumMismatch(let expected, let got):
                return """
                    The downloaded update didn't match its published checksum, so it was discarded.

                    Expected \(expected.prefix(16))…, got \(got.prefix(16))….

                    This usually means a corrupted or interrupted download — try again. Nothing was installed.
                    """
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Check

    static func latest(includePrereleases: Bool = false) async throws -> Release {
        var req = URLRequest(url: manifestURL(prereleases: includePrereleases))
        // The manifest is small and changes rarely; a cached copy would hide a
        // release for as long as the CDN felt like it.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            // A missing manifest is a real state on either channel, not an
            // error: during a beta there is no stable release, and between
            // betas there may be no pre-release.
            if http.statusCode == 404 { throw UpdateError.noChannel(prerelease: includePrereleases) }
            throw UpdateError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw UpdateError.badResponse
        }
    }

    /// True when `remote` is a higher version than the running app.
    static func isNewer(_ remote: String) -> Bool { compare(remote, currentVersion) > 0 }

    // MARK: - Download

    /// Downloads the release and verifies it against the manifest before
    /// returning. An updater that installs whatever arrived is a worse hazard
    /// than one that occasionally refuses.
    static func download(_ release: Release) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: release.url)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let digest = try sha256(of: tmp)
        guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: tmp)
            throw UpdateError.checksumMismatch(expected: release.sha256, got: digest)
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(release.assetName ?? "Transcripts-\(release.version).zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Streamed rather than read whole: the artifact is ~10 MB today, but an
    /// updater that loads the download into memory to hash it is a bug waiting
    /// for the app to grow.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Version compare (pre-release-aware; logic tested in TranscriptsCore)

    static func normalize(_ tag: String) -> String { AppVersion.normalize(tag) }
    static func compare(_ a: String, _ b: String) -> Int { AppVersion.compare(a, b) }
}
