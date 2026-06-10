import CryptoKit
import Foundation

struct AppConfiguration: Codable {
    var deviceID: String
    var deviceName: String
    var watchedFolderPath: String
    var autoSyncEnabled: Bool
    var autoSyncCompletionSoundEnabled: Bool
    var syncIntervalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case deviceID
        case deviceName
        case watchedFolderPath
        case autoSyncEnabled
        case autoSyncCompletionSoundEnabled
        case syncIntervalSeconds
    }

    init(
        deviceID: String,
        deviceName: String,
        watchedFolderPath: String,
        autoSyncEnabled: Bool,
        autoSyncCompletionSoundEnabled: Bool,
        syncIntervalSeconds: Int
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.watchedFolderPath = watchedFolderPath
        self.autoSyncEnabled = autoSyncEnabled
        self.autoSyncCompletionSoundEnabled = autoSyncCompletionSoundEnabled
        self.syncIntervalSeconds = syncIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        watchedFolderPath = try container.decode(String.self, forKey: .watchedFolderPath)
        autoSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSyncEnabled) ?? true
        autoSyncCompletionSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSyncCompletionSoundEnabled) ?? false
        syncIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .syncIntervalSeconds) ?? AppConstants.defaultSyncIntervalSeconds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(watchedFolderPath, forKey: .watchedFolderPath)
        try container.encode(autoSyncEnabled, forKey: .autoSyncEnabled)
        try container.encode(autoSyncCompletionSoundEnabled, forKey: .autoSyncCompletionSoundEnabled)
        try container.encode(syncIntervalSeconds, forKey: .syncIntervalSeconds)
    }

    static func makeDefault() -> AppConfiguration {
        AppConfiguration(
            deviceID: UUID().uuidString,
            deviceName: Host.current().localizedName ?? "Mac",
            watchedFolderPath: "",
            autoSyncEnabled: true,
            autoSyncCompletionSoundEnabled: false,
            syncIntervalSeconds: AppConstants.defaultSyncIntervalSeconds
        )
    }
}

enum SyncTriggerLabel: String, Codable {
    case manual = "手动同步"
    case automatic = "自动同步"

    var priority: Int {
        switch self {
        case .manual:
            return 2
        case .automatic:
            return 1
        }
    }
}

struct DiscoveredPeer: Identifiable, Equatable {
    let id: String
    let displayName: String
}

struct ActivityItem: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let text: String
}

struct SyncProgressSnapshot: Equatable {
    let phase: String
    let detail: String
    let fractionCompleted: Double
    let estimatedCompletionDate: Date?

    var clampedFraction: Double {
        min(max(fractionCompleted, 0), 1)
    }

    var percentText: String {
        "\(Int((clampedFraction * 100).rounded()))%"
    }
}

struct FileFingerprint: Codable, Hashable {
    let contentHash: String
    let size: Int64
    let modifiedAt: Date
    let isDirectory: Bool

    enum CodingKeys: String, CodingKey {
        case contentHash
        case size
        case modifiedAt
        case isDirectory
    }

    init(
        contentHash: String,
        size: Int64,
        modifiedAt: Date,
        isDirectory: Bool = false
    ) {
        self.contentHash = contentHash
        self.size = size
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        size = try container.decode(Int64.self, forKey: .size)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(size, forKey: .size)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDirectory, forKey: .isDirectory)
    }

    var shortSummary: String {
        if isDirectory {
            return "文件夹"
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let sizeText = formatter.string(fromByteCount: size)
        let dateText = Self.summaryFormatter.string(from: modifiedAt)
        return "\(sizeText), \(dateText)"
    }

    private static let summaryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

struct DirectoryManifest: Codable {
    let scannedAt: Date
    let files: [String: FileFingerprint]
}

struct DirectoryDeltaManifest: Codable {
    let scannedAt: Date
    let changedFiles: [String: FileFingerprint]
    let deletedPaths: [String]

    var changedPathCount: Int {
        changedFiles.count + deletedPaths.count
    }

    func hasChange(at path: String) -> Bool {
        changedFiles[path] != nil || deletedPaths.contains(path)
    }

    func resolvedState(for path: String, baselineState: FileFingerprint?) -> FileFingerprint? {
        if deletedPaths.contains(path) {
            return nil
        }
        return changedFiles[path] ?? baselineState
    }
}

enum DirtyPathScope: String, Codable, Hashable {
    case file
    case subtree
}

struct DirtyPathRecord: Codable, Hashable {
    var lastEventID: UInt64
    var scope: DirtyPathScope
}

struct DirectoryDirtyPath: Hashable {
    let path: String
    let scope: DirtyPathScope
    let lastEventID: UInt64
}

struct DirectoryChangeJournal: Codable {
    var lastObservedEventID: UInt64
    var requiresFullRescan: Bool
    var trackedChanges: [String: DirtyPathRecord]
    var updatedAt: Date

    init(
        lastObservedEventID: UInt64 = 0,
        requiresFullRescan: Bool = false,
        trackedChanges: [String: DirtyPathRecord] = [:],
        updatedAt: Date = Date()
    ) {
        self.lastObservedEventID = lastObservedEventID
        self.requiresFullRescan = requiresFullRescan
        self.trackedChanges = trackedChanges
        self.updatedAt = updatedAt
    }

    mutating func noteObservedEventID(_ eventID: UInt64) {
        lastObservedEventID = max(lastObservedEventID, eventID)
        updatedAt = Date()
    }

    mutating func noteFullRescanRequired(observedEventID: UInt64) {
        noteObservedEventID(observedEventID)
        requiresFullRescan = true
    }

    mutating func markHealthy(observedEventID: UInt64) {
        noteObservedEventID(observedEventID)
        requiresFullRescan = false
    }

    mutating func recordChange(path rawPath: String, scope rawScope: DirtyPathScope, eventID: UInt64) {
        noteObservedEventID(eventID)

        let path = normalizedRelativePath(rawPath)
        let scope: DirtyPathScope = path.isEmpty ? .subtree : rawScope

        if let coveringAncestor = ancestorSubtreePath(for: path), coveringAncestor != path || scope == .file {
            if var ancestor = trackedChanges[coveringAncestor] {
                ancestor.lastEventID = max(ancestor.lastEventID, eventID)
                trackedChanges[coveringAncestor] = ancestor
            }
            return
        }

        if scope == .subtree {
            trackedChanges = trackedChanges.filter { existingPath, _ in
                existingPath == path || !isEqualOrDescendantPath(existingPath, of: path)
            }
        }

        if var existing = trackedChanges[path] {
            existing.lastEventID = max(existing.lastEventID, eventID)
            if scope == .subtree {
                existing.scope = .subtree
            }
            trackedChanges[path] = existing
        } else {
            trackedChanges[path] = DirtyPathRecord(lastEventID: eventID, scope: scope)
        }
    }

    mutating func pruneChanges(upTo syncedEventID: UInt64) {
        guard syncedEventID > 0 else {
            return
        }
        trackedChanges = trackedChanges.filter { $0.value.lastEventID > syncedEventID }
        updatedAt = Date()
    }

    func changedPaths(since eventID: UInt64) -> [DirectoryDirtyPath] {
        trackedChanges
            .compactMap { path, record -> DirectoryDirtyPath? in
                guard record.lastEventID > eventID else {
                    return nil
                }
                return DirectoryDirtyPath(path: path, scope: record.scope, lastEventID: record.lastEventID)
            }
            .sorted { lhs, rhs in
                if lhs.path.count != rhs.path.count {
                    return lhs.path.count < rhs.path.count
                }
                if lhs.path != rhs.path {
                    return lhs.path < rhs.path
                }
                return lhs.scope == .subtree && rhs.scope == .file
            }
    }

    private func ancestorSubtreePath(for path: String) -> String? {
        if let record = trackedChanges[path], record.scope == .subtree {
            return path
        }

        var searchPath = path
        while let slash = searchPath.lastIndex(of: "/") {
            searchPath = String(searchPath[..<slash])
            if let record = trackedChanges[searchPath], record.scope == .subtree {
                return searchPath
            }
        }

        if let rootRecord = trackedChanges[""], rootRecord.scope == .subtree {
            return ""
        }
        return nil
    }
}

struct PeerSyncCursorState: Codable {
    let lastSyncedLocalEventID: UInt64
    let updatedAt: Date
}

enum DirectoryScanMode: String {
    case full
    case incremental
}

struct LocalScanResult {
    let manifest: DirectoryManifest
    let delta: DirectoryDeltaManifest
    let mode: DirectoryScanMode
    let filesystemWorkUnits: Int
    let dirtyPathCount: Int
}

struct BaselineChange: Codable, Hashable {
    let path: String
    let resultingState: FileFingerprint?
}

enum PlanRole: String, Codable {
    case initiator
    case responder
}

struct SyncOperation: Codable, Hashable {
    let path: String
    let target: PlanRole
    let source: PlanRole?
    let expectedInitiatorState: FileFingerprint?
    let expectedResponderState: FileFingerprint?
    let resultingState: FileFingerprint?

    var isDeletion: Bool {
        source == nil && resultingState == nil
    }
}

enum ConflictReason: String, Codable {
    case bothModified
    case modifyVsDelete
    case bothCreatedDifferently
}

struct SyncConflict: Codable, Hashable, Identifiable {
    let id: UUID
    let path: String
    let reason: ConflictReason
    let baselineState: FileFingerprint?
    let initiatorState: FileFingerprint?
    let responderState: FileFingerprint?
}

struct SyncPlan: Codable {
    let requestID: UUID
    let operations: [SyncOperation]
    let conflicts: [SyncConflict]
    let baselineChanges: [BaselineChange]
}

struct ApplyFailure: Codable, Hashable {
    let path: String
    let message: String
}

struct BundledFile: Codable, Hashable {
    let path: String
    let fingerprint: FileFingerprint
    let data: Data
}

enum ConflictChoice: String, Codable {
    case useLocal
    case useRemote
}

struct PendingConflict: Identifiable {
    let id: UUID
    let peerDeviceID: String
    let peerName: String
    let conflict: SyncConflict
    let detectedAt: Date
    let remotePreviewURL: URL?

    var localPath: String {
        conflict.path
    }
}

struct HelloMessage: Codable {
    let deviceID: String
    let deviceName: String
    let appVersion: String
    let protocolVersion: Int
}

struct SyncIntentMessage: Codable {
    let requestID: UUID
    let initiatorDeviceID: String
    let trigger: SyncTriggerLabel
}

struct SyncIntentResponseMessage: Codable {
    let requestID: UUID
    let accepted: Bool
    let message: String
}

struct SyncOfferMessage: Codable {
    let requestID: UUID
    let baselineDigest: String
    let delta: DirectoryDeltaManifest
}

struct SyncManifestMessage: Codable {
    let requestID: UUID
    let baselineDigest: String
    let delta: DirectoryDeltaManifest
}

struct RequestedFile: Codable {
    let path: String
    let expectedState: FileFingerprint
}

struct FileRequestMessage: Codable {
    let requestID: UUID
    let files: [RequestedFile]
    let batchIndex: Int
    let totalBatches: Int
    let totalRequestedFiles: Int
    let completedFileCount: Int
}

struct FileBundleMessage: Codable {
    let requestID: UUID
    let files: [BundledFile]
    let failures: [ApplyFailure]
}

struct TransferredFileDescriptor: Codable, Hashable {
    let path: String
    let fingerprint: FileFingerprint
}

struct FileTransferStartMessage: Codable {
    let requestID: UUID
    let files: [TransferredFileDescriptor]
    let failures: [ApplyFailure]
}

struct FileTransferChunkMessage: Codable {
    let requestID: UUID
    let path: String
    let chunkIndex: Int
    let totalChunks: Int
    let data: Data
}

struct FileTransferCompleteMessage: Codable {
    let requestID: UUID
}

struct PlanBundleMessage: Codable {
    let requestID: UUID
    let plan: SyncPlan
    let attachments: [BundledFile]
}

struct ApplyResultMessage: Codable {
    let requestID: UUID
    let failures: [ApplyFailure]
    let note: String
}

struct CommitBaselineMessage: Codable {
    let requestID: UUID
    let changes: [BaselineChange]
}

struct ResolutionBundleMessage: Codable {
    let requestID: UUID
    let conflict: SyncConflict
    let winningSide: PlanRole
    let backupPath: String?
}

struct SyncErrorMessage: Codable {
    let requestID: UUID?
    let message: String
}

enum TransportMessageKind: String, Codable {
    case hello
    case syncIntent
    case syncIntentResponse
    case syncOffer
    case syncManifest
    case fileRequest
    case fileBundle
    case fileTransferStart
    case fileTransferChunk
    case fileTransferComplete
    case planBundle
    case applyResult
    case commitBaseline
    case resolutionBundle
    case syncError
}

struct Envelope: Codable {
    let kind: TransportMessageKind
    let payload: Data
}

enum SyncStateDigest {
    static func digest(for files: [String: FileFingerprint]) -> String {
        let canonical = files
            .sorted { $0.key < $1.key }
            .map { path, fingerprint in
                "\(path)\t\(fingerprint.isDirectory ? "dir" : "file")\t\(fingerprint.contentHash)\t\(fingerprint.size)"
            }
            .joined(separator: "\n")
        let hash = SHA256.hash(data: Data(canonical.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

enum SyncMessageCodec {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func encode<T: Codable>(_ payload: T, kind: TransportMessageKind) throws -> Data {
        let rawPayload = try encoder.encode(payload)
        let envelope = Envelope(kind: kind, payload: rawPayload)
        return try encoder.encode(envelope)
    }

    static func decodeEnvelope(from data: Data) throws -> Envelope {
        try decoder.decode(Envelope.self, from: data)
    }

    static func decodePayload<T: Codable>(_ type: T.Type, from envelope: Envelope) throws -> T {
        try decoder.decode(T.self, from: envelope.payload)
    }
}

func equivalentState(_ lhs: FileFingerprint?, _ rhs: FileFingerprint?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case let (.some(left), .some(right)):
        guard left.isDirectory == right.isDirectory else {
            return false
        }
        if left.isDirectory {
            return true
        }
        return left.contentHash == right.contentHash && left.size == right.size
    default:
        return false
    }
}

func updateBaseline(_ baseline: inout [String: FileFingerprint], with changes: [BaselineChange]) {
    for change in changes {
        if let state = change.resultingState {
            baseline[change.path] = state
        } else {
            baseline.removeValue(forKey: change.path)
        }
    }
}

func sanitizedFilenameComponent(_ raw: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\")
    let parts = raw.components(separatedBy: invalid).filter { !$0.isEmpty }
    let candidate = parts.joined(separator: "_")
    return candidate.isEmpty ? "peer" : candidate
}

func canonicalDirectoryRootPath(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return ""
    }
    return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
}

func stableDigestString(_ raw: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(raw.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func normalizedRelativePath(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return trimmed == "." ? "" : trimmed
}

func isEqualOrDescendantPath(_ path: String, of prefix: String) -> Bool {
    let normalizedPath = normalizedRelativePath(path)
    let normalizedPrefix = normalizedRelativePath(prefix)
    guard !normalizedPrefix.isEmpty else {
        return true
    }
    return normalizedPath == normalizedPrefix || normalizedPath.hasPrefix(normalizedPrefix + "/")
}

func parentRelativePath(of path: String) -> String {
    let normalized = normalizedRelativePath(path)
    guard let slash = normalized.lastIndex(of: "/") else {
        return ""
    }
    return String(normalized[..<slash])
}

func conflictBackupPath(originalPath: String, losingLabel: String, conflictID: UUID) -> String {
    let url = URL(fileURLWithPath: originalPath)
    let directory = url.deletingLastPathComponent().path
    let filename = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    let suffix = "conflict-\(conflictID.uuidString.prefix(8))-\(sanitizedFilenameComponent(losingLabel))"
    let backupName = ext.isEmpty ? "\(filename) (\(suffix))" : "\(filename) (\(suffix)).\(ext)"
    if directory == "." || directory.isEmpty {
        return backupName
    }
    return directory + "/" + backupName
}
