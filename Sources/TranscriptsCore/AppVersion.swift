import Foundation

/// Version ordering for update checks, including pre-releases: `0.8.1-beta.1`
/// sits above every `0.8.0` build and below the final `0.8.1` (semver rule:
/// a pre-release precedes its release). Pure and tested — the updater must
/// never offer a "downgrade" because a suffix confused integer parsing.
public enum AppVersion {

    public static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// The download asset for a release, chosen by version — never "just the first
    /// zip". A release can carry more than one zip (a packaging slip once attached
    /// every past version to every release); picking the first installed an ancient
    /// build in a silent downgrade loop. Prefer the exact `Transcripts-<version>.zip`,
    /// then any zip whose name carries the version, then — only if there's exactly
    /// one zip — that one. nil means "don't guess" (fail loudly rather than install
    /// the wrong version). Pure and tested, because this is the bug that shipped.
    public static func assetName(from names: [String], version: String) -> String? {
        let zips = names.filter { $0.hasSuffix(".zip") }
        let exact = "Transcripts-\(version).zip"
        if let m = zips.first(where: { $0.caseInsensitiveCompare(exact) == .orderedSame }) { return m }
        if let m = zips.first(where: { $0.contains(version) }) { return m }
        return zips.count == 1 ? zips.first : nil
    }

    /// 1 if a > b, -1 if a < b, 0 if equal.
    public static func compare(_ a: String, _ b: String) -> Int {
        let (aRelease, aPre) = split(normalize(a))
        let (bRelease, bPre) = split(normalize(b))

        let x = aRelease.split(separator: ".").map { Int($0) ?? 0 }
        let y = bRelease.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi ? 1 : -1 }
        }

        // Same release: a final build outranks any of its pre-releases.
        switch (aPre, bPre) {
        case (nil, nil): return 0
        case (nil, _): return 1
        case (_, nil): return -1
        case (let ap?, let bp?): return comparePrerelease(ap, bp)
        }
    }

    private static func split(_ v: String) -> (release: String, prerelease: String?) {
        guard let dash = v.firstIndex(of: "-") else { return (v, nil) }
        return (String(v[..<dash]), String(v[v.index(after: dash)...]))
    }

    /// "beta.2" > "beta.1"; numeric identifiers compare numerically, others
    /// lexically (the practical subset of semver §11).
    private static func comparePrerelease(_ a: String, _ b: String) -> Int {
        let xs = a.split(separator: "."), ys = b.split(separator: ".")
        for i in 0..<max(xs.count, ys.count) {
            guard i < xs.count else { return -1 }   // shorter = earlier
            guard i < ys.count else { return 1 }
            let xi = String(xs[i]), yi = String(ys[i])
            if let nx = Int(xi), let ny = Int(yi) {
                if nx != ny { return nx > ny ? 1 : -1 }
            } else if xi != yi {
                return xi > yi ? 1 : -1
            }
        }
        return 0
    }
}
