import CryptoKit
import Foundation

struct AppConfiguration: Codable {
    var deviceID: String
    var deviceName: String
    var watchedFolderPath: String
    var autoSyncEnabled: Bool
    var syncIntervalSeconds: Int

    static func makeDefault() -> AppConfiguration {
        AppConfiguration(
            deviceID: UUID().uuidString,
            deviceName: Host.current().localizedName ?? "Mac",
            watchedFolderPath: "",
            autoSyncEnabled: true,
            syncIntervalSeconds: AppConstants.defaultSyncIntervalSeconds
        )
    }
}

enum SyncTriggerLabel: String, Codable {
    case manual = "手工同步"
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

struct FileFingerprint: Codable, Hashable {
    let contentHash: String
    let size: Int64
    let modifiedAt: Date

    var shortSummary: String {
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
    let manifest: DirectoryManifest
}

struct SyncManifestMessage: Codable {
    let requestID: UUID
    let baselineDigest: String
    let manifest: DirectoryManifest
}

struct RequestedFile: Codable {
    let path: String
    let expectedState: FileFingerprint
}

struct FileRequestMessage: Codable {
    let requestID: UUID
    let files: [RequestedFile]
}

struct FileBundleMessage: Codable {
    let requestID: UUID
    let files: [BundledFile]
    let failures: [ApplyFailure]
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
    let winnerAttachment: BundledFile?
    let loserAttachment: BundledFile?
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
                "\(path)\t\(fingerprint.contentHash)\t\(fingerprint.size)"
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
