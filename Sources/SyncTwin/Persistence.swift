import Foundation

final class AppStorage {
    static let shared = AppStorage()

    private let fileManager = FileManager.default
    private let baseURL: URL
    private let configURL: URL
    private let baselinesDirectoryURL: URL
    private let previewDirectoryURL: URL

    private init() {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseURL = applicationSupport.appendingPathComponent(AppConstants.appName, isDirectory: true)
        configURL = baseURL.appendingPathComponent("config.json")
        baselinesDirectoryURL = baseURL.appendingPathComponent("Baselines", isDirectory: true)
        previewDirectoryURL = baseURL.appendingPathComponent("ConflictPreviews", isDirectory: true)
        try? prepareDirectories()
    }

    func loadConfiguration() -> AppConfiguration {
        guard let data = try? Data(contentsOf: configURL) else {
            return AppConfiguration.makeDefault()
        }
        return (try? SyncMessageCodec.decoder.decode(AppConfiguration.self, from: data)) ?? AppConfiguration.makeDefault()
    }

    func saveConfiguration(_ configuration: AppConfiguration) throws {
        try prepareDirectories()
        let data = try SyncMessageCodec.encoder.encode(configuration)
        try data.write(to: configURL, options: .atomic)
    }

    func loadBaseline(for peerDeviceID: String) -> [String: FileFingerprint] {
        let url = baselineURL(for: peerDeviceID)
        guard let data = try? Data(contentsOf: url) else {
            return [:]
        }
        return (try? SyncMessageCodec.decoder.decode([String: FileFingerprint].self, from: data)) ?? [:]
    }

    func saveBaseline(_ baseline: [String: FileFingerprint], for peerDeviceID: String) throws {
        try prepareDirectories()
        let data = try SyncMessageCodec.encoder.encode(baseline)
        try data.write(to: baselineURL(for: peerDeviceID), options: .atomic)
    }

    func storeRemotePreview(data: Data, conflictID: UUID, originalPath: String) throws -> URL {
        try prepareDirectories()
        let previewName = conflictBackupPath(
            originalPath: originalPath,
            losingLabel: "remote-preview",
            conflictID: conflictID
        )
        let url = previewDirectoryURL.appendingPathComponent(previewName)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    func clearAllPreviewFiles() {
        try? fileManager.removeItem(at: previewDirectoryURL)
        try? fileManager.createDirectory(at: previewDirectoryURL, withIntermediateDirectories: true)
    }

    private func baselineURL(for peerDeviceID: String) -> URL {
        baselinesDirectoryURL
            .appendingPathComponent(sanitizedFilenameComponent(peerDeviceID))
            .appendingPathExtension("json")
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: baselinesDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: previewDirectoryURL, withIntermediateDirectories: true)
    }
}
