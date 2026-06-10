import XCTest
@testable import SyncTwin

final class AppUpdateTests: XCTestCase {
    func testVersionIdentifierHandlesLeadingVAndNumericOrdering() {
        XCTAssertEqual(VersionIdentifier("v1.0.6"), VersionIdentifier("1.0.6"))
        XCTAssertLessThan(VersionIdentifier("1.0.9"), VersionIdentifier("1.0.10"))
        XCTAssertLessThan(VersionIdentifier("1.2.0"), VersionIdentifier("1.10.0"))
    }

    func testPreferredAssetChoosesNamedInstallerPackage() {
        let release = GitHubReleaseInfo(
            tagName: "v1.0.6",
            name: "SyncTwin 1.0.6",
            htmlURL: AppConstants.githubReleasesPageURL,
            body: nil,
            publishedAt: nil,
            assets: [
                GitHubReleaseAsset(
                    name: "notes.txt",
                    browserDownloadURL: AppConstants.githubReleasesPageURL,
                    contentType: "text/plain",
                    size: 32
                ),
                GitHubReleaseAsset(
                    name: "SyncTwin-macOS.zip",
                    browserDownloadURL: AppConstants.githubReleasesPageURL,
                    contentType: "application/zip",
                    size: 2_048
                ),
                GitHubReleaseAsset(
                    name: "other-tool.dmg",
                    browserDownloadURL: AppConstants.githubReleasesPageURL,
                    contentType: "application/x-apple-diskimage",
                    size: 4_096
                ),
            ]
        )

        XCTAssertEqual(release.preferredAsset?.name, "SyncTwin-macOS.zip")
    }
}
