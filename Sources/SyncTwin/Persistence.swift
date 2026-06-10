import Foundation

final class AppStorage {
    static let shared = AppStorage()

    private let fileManager = FileManager.default
    private let baseURL: URL
    private let configURL: URL
    private let baselinesDirectoryURL: URL
    private let localCachesDirectoryURL: URL
    private let journalsDirectoryURL: URL
    private let peerCursorsDirectoryURL: URL
    private let previewDirectoryURL: URL
    private let updatesDirectoryURL: URL

    private init() {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        baseURL = applicationSupport.appendingPathComponent(AppConstants.appName, isDirectory: true)
        configURL = baseURL.appendingPathComponent("config.json")
        baselinesDirectoryURL = baseURL.appendingPathComponent("Baselines", isDirectory: true)
        localCachesDirectoryURL = baseURL.appendingPathComponent("LocalFingerprints", isDirectory: true)
        journalsDirectoryURL = baseURL.appendingPathComponent("DirectoryJournals", isDirectory: true)
        peerCursorsDirectoryURL = baseURL.appendingPathComponent("PeerSyncCursors", isDirectory: true)
        previewDirectoryURL = baseURL.appendingPathComponent("ConflictPreviews", isDirectory: true)
        updatesDirectoryURL = (downloadsDirectory ?? baseURL)
            .appendingPathComponent("\(AppConstants.appName) Updates", isDirectory: true)
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

    func loadBaseline(for peerDeviceID: String, rootPath: String) -> [String: FileFingerprint] {
        let url = baselineURL(for: peerDeviceID, rootPath: rootPath)
        guard let data = try? Data(contentsOf: url) else {
            return [:]
        }
        return (try? SyncMessageCodec.decoder.decode([String: FileFingerprint].self, from: data)) ?? [:]
    }

    func saveBaseline(_ baseline: [String: FileFingerprint], for peerDeviceID: String, rootPath: String) throws {
        try prepareDirectories()
        let data = try SyncMessageCodec.encoder.encode(baseline)
        try data.write(to: baselineURL(for: peerDeviceID, rootPath: rootPath), options: .atomic)
    }

    func loadLocalFingerprintCache(for peerDeviceID: String, rootPath: String) -> [String: FileFingerprint] {
        let url = localFingerprintCacheURL(for: peerDeviceID, rootPath: rootPath)
        guard let data = try? Data(contentsOf: url) else {
            return [:]
        }
        return (try? SyncMessageCodec.decoder.decode([String: FileFingerprint].self, from: data)) ?? [:]
    }

    func saveLocalFingerprintCache(
        _ fingerprints: [String: FileFingerprint],
        for peerDeviceID: String,
        rootPath: String
    ) throws {
        try prepareDirectories()
        let data = try SyncMessageCodec.encoder.encode(fingerprints)
        try data.write(to: localFingerprintCacheURL(for: peerDeviceID, rootPath: rootPath), options: .atomic)
    }

    func hasLocalFingerprintCache(for peerDeviceID: String, rootPath: String) -> Bool {
        fileManager.fileExists(atPath: localFingerprintCacheURL(for: peerDeviceID, rootPath: rootPath).path)
    }

    func loadDirectoryChangeJournal(rootPath: String) -> DirectoryChangeJournal {
        let url = directoryChangeJournalURL(for: rootPath)
        guard let data = try? Data(contentsOf: url) else {
            return DirectoryChangeJournal()
        }
        return (try? SyncMessageCodec.decoder.decode(DirectoryChangeJournal.self, from: data)) ?? DirectoryChangeJournal()
    }

    func saveDirectoryChangeJournal(_ journal: DirectoryChangeJournal, rootPath: String) throws {
        try prepareDirectories()
        let data = try SyncMessageCodec.encoder.encode(journal)
        try data.write(to: directoryChangeJournalURL(for: rootPath), options: .atomic)
    }

    func loadPeerSyncCursor(for peerDeviceID: String, rootPath: String) -> PeerSyncCursorState? {
        let url = peerSyncCursorURL(for: peerDeviceID, rootPath: rootPath)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? SyncMessageCodec.decoder.decode(PeerSyncCursorState.self, from: data)
    }

    func savePeerSyncCursor(
        _ cursor: PeerSyncCursorState,
        for peerDeviceID: String,
        rootPath: String
    ) throws {
        try prepareDirectories()
        let rootDirectory = peerSyncCursorDirectoryURL(for: rootPath)
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let data = try SyncMessageCodec.encoder.encode(cursor)
        try data.write(to: peerSyncCursorURL(for: peerDeviceID, rootPath: rootPath), options: .atomic)
        try pruneDirectoryChangeJournal(rootPath: rootPath)
    }

    func clearDirectoryChangeJournalFullRescanFlag(rootPath: String, observedEventID: UInt64) throws {
        var journal = loadDirectoryChangeJournal(rootPath: rootPath)
        journal.markHealthy(observedEventID: observedEventID)
        try saveDirectoryChangeJournal(journal, rootPath: rootPath)
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

    func existingDownloadedUpdateURL(releaseTag: String, assetName: String) -> URL? {
        let url = downloadedUpdateURL(releaseTag: releaseTag, assetName: assetName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func storeDownloadedUpdate(from temporaryURL: URL, releaseTag: String, assetName: String) throws -> URL {
        try prepareDirectories()
        let releaseDirectory = downloadedUpdateDirectoryURL(for: releaseTag)
        try fileManager.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)

        let destinationURL = downloadedUpdateURL(releaseTag: releaseTag, assetName: assetName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func baselineURL(for peerDeviceID: String, rootPath: String) -> URL {
        let directoryKey = stableDigestString(rootPath)
        return baselinesDirectoryURL
            .appendingPathComponent("\(sanitizedFilenameComponent(peerDeviceID))-\(directoryKey)")
            .appendingPathExtension("json")
    }

    private func localFingerprintCacheURL(for peerDeviceID: String, rootPath: String) -> URL {
        let directoryKey = stableDigestString(rootPath)
        return localCachesDirectoryURL
            .appendingPathComponent("\(sanitizedFilenameComponent(peerDeviceID))-\(directoryKey)")
            .appendingPathExtension("json")
    }

    private func directoryChangeJournalURL(for rootPath: String) -> URL {
        journalsDirectoryURL
            .appendingPathComponent(stableDigestString(rootPath))
            .appendingPathExtension("json")
    }

    private func peerSyncCursorDirectoryURL(for rootPath: String) -> URL {
        peerCursorsDirectoryURL.appendingPathComponent(stableDigestString(rootPath), isDirectory: true)
    }

    private func peerSyncCursorURL(for peerDeviceID: String, rootPath: String) -> URL {
        peerSyncCursorDirectoryURL(for: rootPath)
            .appendingPathComponent(sanitizedFilenameComponent(peerDeviceID))
            .appendingPathExtension("json")
    }

    private func downloadedUpdateDirectoryURL(for releaseTag: String) -> URL {
        updatesDirectoryURL.appendingPathComponent(sanitizedFilenameComponent(releaseTag), isDirectory: true)
    }

    private func downloadedUpdateURL(releaseTag: String, assetName: String) -> URL {
        downloadedUpdateDirectoryURL(for: releaseTag)
            .appendingPathComponent(sanitizedFilenameComponent(assetName))
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: baselinesDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: localCachesDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: journalsDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: peerCursorsDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: previewDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: updatesDirectoryURL, withIntermediateDirectories: true)
    }

    private func pruneDirectoryChangeJournal(rootPath: String) throws {
        var journal = loadDirectoryChangeJournal(rootPath: rootPath)
        let peerCursorDirectory = peerSyncCursorDirectoryURL(for: rootPath)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: peerCursorDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let cursors = contents.compactMap { url -> PeerSyncCursorState? in
            guard let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? SyncMessageCodec.decoder.decode(PeerSyncCursorState.self, from: data)
        }

        guard let minimumCursor = cursors.map(\.lastSyncedLocalEventID).min(), minimumCursor > 0 else {
            return
        }

        journal.pruneChanges(upTo: minimumCursor)
        try saveDirectoryChangeJournal(journal, rootPath: rootPath)
    }
}
