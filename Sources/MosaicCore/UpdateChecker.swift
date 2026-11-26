import Foundation

public struct SemanticVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let core = withoutPrefix.split(separator: "-", maxSplits: 1).first.map(String.init) ?? withoutPrefix
        let parts = core.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }

        self.major = parts[0]
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case notConfigured(currentVersion: String)
    case upToDate(currentVersion: String)
    case updateAvailable(currentVersion: String, latestVersion: String, releaseURL: URL, releaseNotes: String)
    case failed(String)
}

private struct GitHubReleaseResponse: Decodable {
    let tag_name: String
    let html_url: String
    let body: String?
}

public enum UpdateChecker {
    public static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    public static var configuredGitHubRepo: String {
        (Bundle.main.infoDictionary?["CatHideGitHubRepo"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func checkForUpdates(
        currentVersion: String = currentAppVersion,
        githubRepo: String = configuredGitHubRepo
    ) async -> UpdateCheckResult {
        let repo = githubRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else {
            return .notConfigured(currentVersion: currentVersion)
        }

        guard let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failed("GitHub 仓库配置格式无效：\(repo)")
        }

        var request = URLRequest(url: apiURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CatHide/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("无法获取服务器响应。")
            }
            if http.statusCode == 404 {
                return .upToDate(currentVersion: currentVersion)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed("检查更新失败（HTTP \(http.statusCode)）。")
            }

            let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
            guard let current = SemanticVersion(currentVersion),
                  let latest = SemanticVersion(release.tag_name),
                  let releaseURL = URL(string: release.html_url) else {
                return .failed("无法解析远端版本信息（\(release.tag_name)）。")
            }

            if latest > current {
                return .updateAvailable(
                    currentVersion: currentVersion,
                    latestVersion: release.tag_name,
                    releaseURL: releaseURL,
                    releaseNotes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
            }
            return .upToDate(currentVersion: currentVersion)
        } catch {
            return .failed("网络请求失败：\(error.localizedDescription)")
        }
    }
}
