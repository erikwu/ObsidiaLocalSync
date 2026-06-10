import Foundation

enum UpdateCheckTrigger {
    case automaticOnLaunch
    case manual
}

enum AppUpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case downloading
    case downloaded
    case failed
}

struct AppUpdateSnapshot: Equatable {
    let phase: AppUpdatePhase
    let detail: String
    let latestVersion: String?
    let releasePageURL: URL?
    let downloadedFileURL: URL?
    let lastCheckedAt: Date?
    let assetName: String?

    var isBusy: Bool {
        phase == .checking || phase == .downloading
    }

    static let idle = AppUpdateSnapshot(
        phase: .idle,
        detail: "启动时会自动检查 GitHub Release，并在发现新版本时自动下载。",
        latestVersion: nil,
        releasePageURL: AppConstants.githubReleasesPageURL,
        downloadedFileURL: nil,
        lastCheckedAt: nil,
        assetName: nil
    )
}

struct VersionIdentifier: Comparable {
    let rawValue: String
    let normalizedValue: String
    private let numericComponents: [Int]

    init(_ rawValue: String) {
        self.rawValue = rawValue
        normalizedValue = Self.normalize(rawValue)
        numericComponents = normalizedValue
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    static func normalize(_ rawValue: String) -> String {
        var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = normalized.first,
           (first == "v" || first == "V"),
           normalized.dropFirst().first?.isNumber == true {
            normalized.removeFirst()
        }
        return normalized
    }

    static func < (lhs: VersionIdentifier, rhs: VersionIdentifier) -> Bool {
        if !lhs.numericComponents.isEmpty || !rhs.numericComponents.isEmpty {
            let count = max(lhs.numericComponents.count, rhs.numericComponents.count)
            for index in 0..<count {
                let left = index < lhs.numericComponents.count ? lhs.numericComponents[index] : 0
                let right = index < rhs.numericComponents.count ? rhs.numericComponents[index] : 0
                if left != right {
                    return left < right
                }
            }
        }
        return lhs.normalizedValue.localizedStandardCompare(rhs.normalizedValue) == .orderedAscending
    }

    static func == (lhs: VersionIdentifier, rhs: VersionIdentifier) -> Bool {
        if !lhs.numericComponents.isEmpty || !rhs.numericComponents.isEmpty {
            let count = max(lhs.numericComponents.count, rhs.numericComponents.count)
            for index in 0..<count {
                let left = index < lhs.numericComponents.count ? lhs.numericComponents[index] : 0
                let right = index < rhs.numericComponents.count ? rhs.numericComponents[index] : 0
                if left != right {
                    return false
                }
            }
            return true
        }
        return lhs.normalizedValue.caseInsensitiveCompare(rhs.normalizedValue) == .orderedSame
    }
}

struct GitHubReleaseAsset: Decodable, Equatable {
    let name: String
    let browserDownloadURL: URL
    let contentType: String?
    let size: Int64

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case contentType = "content_type"
        case size
    }

    private var fileExtension: String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }

    var isSupportedInstallerAsset: Bool {
        ["zip", "dmg", "pkg"].contains(fileExtension)
    }

    var sortScore: Int {
        let lowercasedName = name.lowercased()
        let nameScore = lowercasedName.contains(AppConstants.appName.lowercased()) ? 100 : 0
        let extensionScore: Int
        switch fileExtension {
        case "zip":
            extensionScore = 30
        case "dmg":
            extensionScore = 20
        case "pkg":
            extensionScore = 10
        default:
            extensionScore = 0
        }
        return nameScore + extensionScore
    }
}

struct GitHubReleaseInfo: Decodable, Equatable {
    let tagName: String
    let name: String
    let htmlURL: URL
    let body: String?
    let publishedAt: Date?
    let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
        case publishedAt = "published_at"
        case assets
    }

    var normalizedVersion: String {
        VersionIdentifier.normalize(tagName)
    }

    var preferredAsset: GitHubReleaseAsset? {
        assets
            .filter(\.isSupportedInstallerAsset)
            .sorted { left, right in
                if left.sortScore != right.sortScore {
                    return left.sortScore > right.sortScore
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            .first
    }
}

enum AppUpdateServiceError: LocalizedError {
    case invalidResponse
    case requestFailed(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "更新服务返回了无法识别的数据。"
        case let .requestFailed(statusCode, message):
            if let message, !message.isEmpty {
                return "更新服务请求失败（\(statusCode)）：\(message)"
            }
            return "更新服务请求失败（\(statusCode)）。"
        }
    }
}

struct GitHubReleaseUpdateService {
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func fetchLatestRelease() async throws -> GitHubReleaseInfo {
        let request = makeRequest(url: AppConstants.githubLatestReleaseAPIURL)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(GitHubReleaseInfo.self, from: data)
    }

    func downloadAsset(_ asset: GitHubReleaseAsset) async throws -> URL {
        let request = makeRequest(url: asset.browserDownloadURL)
        let (temporaryURL, response) = try await session.download(for: request)
        try validate(response: response, data: nil)
        return temporaryURL
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppConstants.appName)/\(AppConstants.appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppUpdateServiceError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }
    }
}
