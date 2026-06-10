import Foundation

enum AppConstants {
    static let appName = "SyncTwin"
    static let appVersion = "1.0.7"
    static let protocolVersion = 2
    static let serviceType = "synctwinlan"
    static let defaultSyncIntervalSeconds = 300
    static let maxInlineFileBytes = 32 * 1_024 * 1_024
    static let maxTransferBatchBytes = 4 * 1_024 * 1_024
    static let maxTransferBatchFiles = 128
    static let maxOperationBatchCount = 128
    static let githubReleasesPageURL = URL(string: "https://github.com/erikwu/ObsidiaLocalSync/releases")!
    static let githubLatestReleaseAPIURL = URL(string: "https://api.github.com/repos/erikwu/ObsidiaLocalSync/releases/latest")!
}
