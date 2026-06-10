import AppKit
import Foundation

enum SyncTriggerLabel: String {
    case manual = "手工同步"
    case automatic = "自动同步"
}

enum SyncControllerError: LocalizedError {
    case transportUnavailable
    case noConnectedPeer
    case noFolderConfigured
    case versionMismatch(String)
    case baselineMismatch
    case timeout(String)
    case localStateChanged(String)
    case peerChanged(String)

    var errorDescription: String? {
        switch self {
        case .transportUnavailable:
            return "本地连接服务不可用。"
        case .noConnectedPeer:
            return "请先连接另一台已安装 SyncTwin 的 Mac。"
        case .noFolderConfigured:
            return "请先选择需要同步的目录。"
        case let .versionMismatch(message):
            return message
        case .baselineMismatch:
            return "两台电脑保存的同步基线不一致，已拒绝同步。请在两端确认目录一致后再重试。"
        case let .timeout(stage):
            return "\(stage) 超时，请检查两台电脑是否都在线。"
        case let .localStateChanged(path):
            return "文件 \(path) 在你处理期间又被修改了，当前冲突需要重新同步后再判断。"
        case let .peerChanged(path):
            return "对端的 \(path) 已发生新变化，当前冲突需要重新同步后再判断。"
        }
    }
}

@MainActor
final class SyncTwinController: NSObject, ObservableObject {
    @Published var config: AppConfiguration
    @Published var discoveredPeers: [DiscoveredPeer] = []
    @Published var connectedPeerName: String?
    @Published var remoteHello: HelloMessage?
    @Published var statusText = "正在等待局域网内的另一台电脑。"
    @Published var isSyncInProgress = false
    @Published var pendingConflicts: [PendingConflict] = []
    @Published var activityItems: [ActivityItem] = []

    private let storage = AppStorage.shared
    private let scanner = DirectoryScanner()
    private let planner = SyncPlanner()

    private var transport: PeerTransport?
    private var autoSyncTask: Task<Void, Never>?

    private var manifestWaiters: [UUID: CheckedContinuation<SyncManifestMessage, Error>] = [:]
    private var fileWaiters: [UUID: CheckedContinuation<FileBundleMessage, Error>] = [:]
    private var applyWaiters: [UUID: CheckedContinuation<ApplyResultMessage, Error>] = [:]

    override init() {
        config = storage.loadConfiguration()
        super.init()
        storage.clearAllPreviewFiles()
        startTransport()
        scheduleAutoSyncLoop()
        addLog("应用已启动，版本 \(AppConstants.appVersion)。")
    }

    deinit {
        autoSyncTask?.cancel()
        transport?.stop()
    }

    var watchedFolderURL: URL? {
        guard !config.watchedFolderPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: config.watchedFolderPath, isDirectory: true)
    }

    var watchedFolderDisplayName: String {
        guard let watchedFolderURL else {
            return "尚未选择目录"
        }
        return watchedFolderURL.path
    }

    var versionGateMessage: String? {
        guard let remoteHello else {
            return nil
        }
        if remoteHello.appVersion != AppConstants.appVersion {
            return "对端版本 \(remoteHello.appVersion) 与本机 \(AppConstants.appVersion) 不一致，已禁止同步。"
        }
        if remoteHello.protocolVersion != AppConstants.protocolVersion {
            return "对端协议版本与本机不兼容，已禁止同步。"
        }
        return nil
    }

    var canSyncNow: Bool {
        connectedPeerName != nil && remoteHello != nil && versionGateMessage == nil && watchedFolderURL != nil && !isSyncInProgress
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择目录"

        if panel.runModal() == .OK, let url = panel.url {
            config.watchedFolderPath = url.path
            saveSettings()
        }
    }

    func saveSettings() {
        let oldDisplayName = transport?.localPeerID.displayName

        config.deviceName = config.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.deviceName.isEmpty {
            config.deviceName = Host.current().localizedName ?? "Mac"
        }
        config.syncIntervalSeconds = max(60, config.syncIntervalSeconds)

        do {
            try storage.saveConfiguration(config)
            addLog("设置已保存。")
            statusText = "设置已保存。"
        } catch {
            statusText = "保存设置失败：\(error.localizedDescription)"
            addLog(statusText)
        }

        if oldDisplayName != config.deviceName {
            startTransport()
        }
        scheduleAutoSyncLoop()
    }

    func connect(to peer: DiscoveredPeer) {
        guard let transport else {
            statusText = "连接服务尚未准备好。"
            return
        }
        statusText = "正在连接 \(peer.displayName)..."
        addLog(statusText)
        transport.invite(peerNamed: peer.displayName)
    }

    func disconnect() {
        transport?.disconnect()
        clearConnectionState(message: "已主动断开连接。")
    }

    func startManualSync() {
        beginSync(trigger: .manual)
    }

    func resolve(_ pending: PendingConflict, choice: ConflictChoice) {
        guard !isSyncInProgress else {
            statusText = "请先等待当前同步结束，再处理冲突。"
            return
        }

        Task {
            await performConflictResolution(pending, choice: choice)
        }
    }

    func openLocalVersion(for pending: PendingConflict) {
        guard let root = watchedFolderURL else {
            return
        }
        let url = scanner.absoluteURL(root: root, relativePath: pending.localPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    func openRemotePreview(for pending: PendingConflict) {
        guard let url = pending.remotePreviewURL else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func startTransport() {
        transport?.stop()
        let transport = PeerTransport(displayName: config.deviceName)
        transport.delegate = self
        transport.start()
        self.transport = transport
        addLog("开始在局域网内广播设备 \(config.deviceName)。")
    }

    private func scheduleAutoSyncLoop() {
        autoSyncTask?.cancel()

        guard config.autoSyncEnabled else {
            return
        }

        autoSyncTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let seconds = max(60, self.config.syncIntervalSeconds)
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                await self.maybeRunAutomaticSync()
            }
        }
    }

    private func maybeRunAutomaticSync() async {
        guard config.autoSyncEnabled, !isSyncInProgress else {
            return
        }
        guard let remoteHello else {
            return
        }
        guard connectedPeerName != nil else {
            return
        }
        guard versionGateMessage == nil else {
            return
        }
        guard watchedFolderURL != nil else {
            return
        }

        if config.deviceID < remoteHello.deviceID {
            beginSync(trigger: .automatic)
        }
    }

    private func beginSync(trigger: SyncTriggerLabel) {
        guard !isSyncInProgress else {
            statusText = "已有同步任务正在进行中。"
            return
        }

        Task {
            await performSync(trigger: trigger)
        }
    }

    private func performSync(trigger: SyncTriggerLabel) async {
        guard let peerName = connectedPeerName, let peerHello = remoteHello else {
            statusText = SyncControllerError.noConnectedPeer.localizedDescription
            return
        }
        if let versionGateMessage {
            statusText = versionGateMessage
            addLog(versionGateMessage)
            return
        }
        guard let root = watchedFolderURL else {
            statusText = SyncControllerError.noFolderConfigured.localizedDescription
            return
        }
        guard let transport else {
            statusText = SyncControllerError.transportUnavailable.localizedDescription
            return
        }

        isSyncInProgress = true
        statusText = "\(trigger.rawValue)中..."
        addLog("开始\(trigger.rawValue)，目标：\(peerName)。")

        defer {
            isSyncInProgress = false
        }

        do {
            let baseline = storage.loadBaseline(for: peerHello.deviceID)
            let localManifest = try await scanManifest(root: root)
            let baselineDigest = SyncStateDigest.digest(for: baseline)
            let requestID = UUID()

            let manifestMessage = try await requestRemoteManifest(
                requestID: requestID,
                baselineDigest: baselineDigest,
                localManifest: localManifest,
                peerName: peerName,
                transport: transport
            )

            guard manifestMessage.baselineDigest == baselineDigest else {
                throw SyncControllerError.baselineMismatch
            }

            let plan = planner.makePlan(
                requestID: requestID,
                baseline: baseline,
                initiator: localManifest.files,
                responder: manifestMessage.manifest.files
            )

            let requestedRemoteFiles = uniqueRequestedFiles(from: plan)
            let remoteBundleMessage = try await requestFiles(
                requestID: requestID,
                files: requestedRemoteFiles,
                peerName: peerName,
                transport: transport
            )
            let remoteFilesByPath = Dictionary(uniqueKeysWithValues: remoteBundleMessage.files.map { ($0.path, $0) })

            let localAttachmentBuild = buildLocalAttachments(
                for: plan.operations.filter { $0.target == .responder && $0.source == .initiator },
                root: root
            )

            let remoteApplyTask = Task {
                try await self.sendPlanAndAwaitResult(
                    requestID: requestID,
                    plan: plan,
                    attachments: localAttachmentBuild.files,
                    peerName: peerName,
                    transport: transport
                )
            }

            let localFailures = try await applyOperations(
                plan.operations.filter { $0.target == .initiator },
                on: root,
                localRole: .initiator,
                remoteFilesByPath: remoteFilesByPath
            )

            let remoteApplyResult = try await remoteApplyTask.value

            let failurePaths = Set(
                remoteBundleMessage.failures.map(\.path)
                    + localAttachmentBuild.failures.map(\.path)
                    + localFailures.map(\.path)
                    + remoteApplyResult.failures.map(\.path)
            )

            let commitChanges = plan.baselineChanges.filter { !failurePaths.contains($0.path) }
            if !commitChanges.isEmpty {
                var updatedBaseline = baseline
                updateBaseline(&updatedBaseline, with: commitChanges)
                try storage.saveBaseline(updatedBaseline, for: peerHello.deviceID)
                try transport.sendPayload(
                    CommitBaselineMessage(requestID: requestID, changes: commitChanges),
                    kind: .commitBaseline,
                    to: peerName
                )
            }

            registerPendingConflicts(plan.conflicts, remoteFilesByPath: remoteFilesByPath, peerHello: peerHello)

            if !plan.conflicts.isEmpty {
                statusText = "安全变更已自动同步，另有 \(plan.conflicts.count) 个冲突等待人工判断。"
            } else if !failurePaths.isEmpty {
                statusText = "同步部分完成，\(failurePaths.count) 个文件需要重试。"
            } else {
                statusText = "同步完成，没有发生内容丢失。"
            }
            addLog(statusText)
        } catch {
            statusText = error.localizedDescription
            addLog(statusText)
        }
    }

    private func performConflictResolution(_ pending: PendingConflict, choice: ConflictChoice) async {
        guard let transport, let peerName = connectedPeerName, let peerHello = remoteHello else {
            statusText = SyncControllerError.noConnectedPeer.localizedDescription
            return
        }
        guard peerHello.deviceID == pending.peerDeviceID else {
            statusText = "当前连接的不是产生该冲突的那台电脑。"
            return
        }
        guard let root = watchedFolderURL else {
            statusText = SyncControllerError.noFolderConfigured.localizedDescription
            return
        }
        if let versionGateMessage {
            statusText = versionGateMessage
            return
        }

        isSyncInProgress = true
        statusText = "正在处理冲突 \(pending.conflict.path)..."
        addLog(statusText)

        defer {
            isSyncInProgress = false
        }

        do {
            let currentLocalState = try await currentState(for: pending.conflict.path, root: root)
            guard equivalentState(currentLocalState, pending.conflict.initiatorState) else {
                throw SyncControllerError.localStateChanged(pending.conflict.path)
            }

            let remoteBundle = try await ensureRemoteBundle(for: pending, peerName: peerName, transport: transport)
            let winningSide: PlanRole = choice == .useLocal ? .initiator : .responder
            let losingLabel = winningSide == .initiator ? peerHello.deviceName : config.deviceName
            let losingState = winningSide == .initiator ? pending.conflict.responderState : pending.conflict.initiatorState
            let backupPath = losingState == nil ? nil : conflictBackupPath(
                originalPath: pending.conflict.path,
                losingLabel: losingLabel,
                conflictID: pending.conflict.id
            )

            let winnerAttachment: BundledFile?
            let loserAttachment: BundledFile?

            switch winningSide {
            case .initiator:
                if let winnerState = pending.conflict.initiatorState {
                    winnerAttachment = try scanner.bundleFile(root: root, relativePath: pending.conflict.path, expectedState: winnerState)
                } else {
                    winnerAttachment = nil
                }
                loserAttachment = nil

            case .responder:
                winnerAttachment = nil
                if let loserState = pending.conflict.initiatorState {
                    loserAttachment = try scanner.bundleFile(root: root, relativePath: pending.conflict.path, expectedState: loserState)
                } else {
                    loserAttachment = nil
                }
            }

            let requestID = UUID()
            let remoteApplyTask = Task {
                try await self.sendResolutionAndAwaitResult(
                    message: ResolutionBundleMessage(
                        requestID: requestID,
                        conflict: pending.conflict,
                        winningSide: winningSide,
                        backupPath: backupPath,
                        winnerAttachment: winnerAttachment,
                        loserAttachment: loserAttachment
                    ),
                    peerName: peerName,
                    transport: transport
                )
            }

            let localFailures = try await applyResolutionLocally(
                conflict: pending.conflict,
                winningSide: winningSide,
                backupPath: backupPath,
                remoteBundle: remoteBundle,
                root: root
            )

            let remoteApplyResult = try await remoteApplyTask.value
            let failurePaths = Set(localFailures.map(\.path) + remoteApplyResult.failures.map(\.path))

            var baselineChanges = [
                BaselineChange(
                    path: pending.conflict.path,
                    resultingState: winningSide == .initiator ? pending.conflict.initiatorState : pending.conflict.responderState
                ),
            ]
            if let backupPath, let losingState {
                baselineChanges.append(BaselineChange(path: backupPath, resultingState: losingState))
            }

            if !failurePaths.isEmpty {
                statusText = "冲突处理部分完成，建议重新同步确认最新状态。"
                addLog(statusText)
                return
            }

            let baseline = storage.loadBaseline(for: peerHello.deviceID)
            var updatedBaseline = baseline
            updateBaseline(&updatedBaseline, with: baselineChanges)
            try storage.saveBaseline(updatedBaseline, for: peerHello.deviceID)
            try transport.sendPayload(
                CommitBaselineMessage(requestID: requestID, changes: baselineChanges),
                kind: .commitBaseline,
                to: peerName
            )

            pendingConflicts.removeAll { $0.id == pending.id }
            statusText = "冲突已处理，未选中的版本已保留为冲突副本。"
            addLog(statusText)
        } catch {
            statusText = error.localizedDescription
            addLog(statusText)
        }
    }

    private func registerPendingConflicts(
        _ conflicts: [SyncConflict],
        remoteFilesByPath: [String: BundledFile],
        peerHello: HelloMessage
    ) {
        pendingConflicts.removeAll { $0.peerDeviceID == peerHello.deviceID }

        let newConflicts = conflicts.compactMap { conflict -> PendingConflict? in
            let previewURL: URL?
            if let remoteFile = remoteFilesByPath[conflict.path] {
                previewURL = try? storage.storeRemotePreview(
                    data: remoteFile.data,
                    conflictID: conflict.id,
                    originalPath: conflict.path
                )
            } else {
                previewURL = nil
            }

            return PendingConflict(
                id: conflict.id,
                peerDeviceID: peerHello.deviceID,
                peerName: peerHello.deviceName,
                conflict: conflict,
                detectedAt: Date(),
                remotePreviewURL: previewURL
            )
        }

        pendingConflicts.append(contentsOf: newConflicts)
    }

    private func uniqueRequestedFiles(from plan: SyncPlan) -> [RequestedFile] {
        var map: [String: RequestedFile] = [:]

        for operation in plan.operations where operation.target == .initiator && operation.source == .responder {
            if let expected = operation.resultingState {
                map[operation.path] = RequestedFile(path: operation.path, expectedState: expected)
            }
        }

        for conflict in plan.conflicts {
            if let expected = conflict.responderState {
                map[conflict.path] = RequestedFile(path: conflict.path, expectedState: expected)
            }
        }

        return map.keys.sorted().compactMap { map[$0] }
    }

    private func buildLocalAttachments(for operations: [SyncOperation], root: URL) -> (files: [BundledFile], failures: [ApplyFailure]) {
        var files: [BundledFile] = []
        var failures: [ApplyFailure] = []

        for operation in operations {
            guard let expected = operation.resultingState else {
                continue
            }
            do {
                let file = try scanner.bundleFile(root: root, relativePath: operation.path, expectedState: expected)
                files.append(file)
            } catch {
                failures.append(ApplyFailure(path: operation.path, message: error.localizedDescription))
            }
        }

        return (files, failures)
    }

    private func applyOperations(
        _ operations: [SyncOperation],
        on root: URL,
        localRole: PlanRole,
        remoteFilesByPath: [String: BundledFile]
    ) async throws -> [ApplyFailure] {
        let scanner = DirectoryScanner()
        return try await Task.detached(priority: .userInitiated) {
            var failures: [ApplyFailure] = []

            for operation in operations {
                let expectedState = localRole == .initiator ? operation.expectedInitiatorState : operation.expectedResponderState
                let currentState = try scanner.currentState(root: root, relativePath: operation.path)
                guard equivalentState(currentState, expectedState) else {
                    failures.append(ApplyFailure(path: operation.path, message: "同步前该文件又发生了变化。"))
                    continue
                }

                if operation.isDeletion {
                    do {
                        try scanner.deleteItem(root: root, relativePath: operation.path)
                    } catch {
                        failures.append(ApplyFailure(path: operation.path, message: error.localizedDescription))
                    }
                    continue
                }

                guard let source = operation.source, let resultState = operation.resultingState else {
                    failures.append(ApplyFailure(path: operation.path, message: "无效的同步操作。"))
                    continue
                }

                let fileToWrite: BundledFile
                if source == localRole {
                    do {
                        fileToWrite = try scanner.bundleFile(root: root, relativePath: operation.path, expectedState: resultState)
                    } catch {
                        failures.append(ApplyFailure(path: operation.path, message: error.localizedDescription))
                        continue
                    }
                } else {
                    guard let remoteFile = remoteFilesByPath[operation.path], equivalentState(remoteFile.fingerprint, resultState) else {
                        failures.append(ApplyFailure(path: operation.path, message: "没有拿到对端文件内容。"))
                        continue
                    }
                    fileToWrite = BundledFile(path: operation.path, fingerprint: remoteFile.fingerprint, data: remoteFile.data)
                }

                do {
                    try scanner.writeFile(fileToWrite, into: root)
                } catch {
                    failures.append(ApplyFailure(path: operation.path, message: error.localizedDescription))
                }
            }

            return failures
        }.value
    }

    private func applyResolutionLocally(
        conflict: SyncConflict,
        winningSide: PlanRole,
        backupPath: String?,
        remoteBundle: BundledFile?,
        root: URL
    ) async throws -> [ApplyFailure] {
        let scanner = DirectoryScanner()
        return try await Task.detached(priority: .userInitiated) {
            var failures: [ApplyFailure] = []
            let currentState = try scanner.currentState(root: root, relativePath: conflict.path)
            guard equivalentState(currentState, conflict.initiatorState) else {
                return [ApplyFailure(path: conflict.path, message: "本地文件在处理前已变化。")]
            }

            if winningSide == .initiator {
                if let backupPath, let remoteBundle {
                    do {
                        try scanner.writeData(
                            remoteBundle.data,
                            to: root,
                            relativePath: backupPath,
                            modifiedAt: remoteBundle.fingerprint.modifiedAt
                        )
                    } catch {
                        failures.append(ApplyFailure(path: backupPath, message: error.localizedDescription))
                    }
                }

                if conflict.initiatorState == nil {
                    do {
                        try scanner.deleteItem(root: root, relativePath: conflict.path)
                    } catch {
                        failures.append(ApplyFailure(path: conflict.path, message: error.localizedDescription))
                    }
                }
            } else {
                if let backupPath, let localState = conflict.initiatorState {
                    do {
                        let localFile = try scanner.bundleFile(root: root, relativePath: conflict.path, expectedState: localState)
                        try scanner.writeData(localFile.data, to: root, relativePath: backupPath, modifiedAt: localFile.fingerprint.modifiedAt)
                    } catch {
                        failures.append(ApplyFailure(path: backupPath, message: error.localizedDescription))
                    }
                }

                if let remoteState = conflict.responderState {
                    guard let remoteBundle, equivalentState(remoteBundle.fingerprint, remoteState) else {
                        failures.append(ApplyFailure(path: conflict.path, message: "对端预览内容已经过期。"))
                        return failures
                    }
                    do {
                        try scanner.writeData(
                            remoteBundle.data,
                            to: root,
                            relativePath: conflict.path,
                            modifiedAt: remoteBundle.fingerprint.modifiedAt
                        )
                    } catch {
                        failures.append(ApplyFailure(path: conflict.path, message: error.localizedDescription))
                    }
                } else {
                    do {
                        try scanner.deleteItem(root: root, relativePath: conflict.path)
                    } catch {
                        failures.append(ApplyFailure(path: conflict.path, message: error.localizedDescription))
                    }
                }
            }

            return failures
        }.value
    }

    private func requestRemoteManifest(
        requestID: UUID,
        baselineDigest: String,
        localManifest: DirectoryManifest,
        peerName: String,
        transport: PeerTransport
    ) async throws -> SyncManifestMessage {
        do {
            return try await withTimeout("同步清单交换") {
                try await withCheckedThrowingContinuation { continuation in
                    self.manifestWaiters[requestID] = continuation
                    do {
                        try transport.sendPayload(
                            SyncOfferMessage(requestID: requestID, baselineDigest: baselineDigest, manifest: localManifest),
                            kind: .syncOffer,
                            to: peerName
                        )
                    } catch {
                        self.manifestWaiters.removeValue(forKey: requestID)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            manifestWaiters.removeValue(forKey: requestID)
            throw error
        }
    }

    private func requestFiles(
        requestID: UUID,
        files: [RequestedFile],
        peerName: String,
        transport: PeerTransport
    ) async throws -> FileBundleMessage {
        guard !files.isEmpty else {
            return FileBundleMessage(requestID: requestID, files: [], failures: [])
        }

        do {
            return try await withTimeout("文件拉取") {
                try await withCheckedThrowingContinuation { continuation in
                    self.fileWaiters[requestID] = continuation
                    do {
                        try transport.sendPayload(
                            FileRequestMessage(requestID: requestID, files: files),
                            kind: .fileRequest,
                            to: peerName
                        )
                    } catch {
                        self.fileWaiters.removeValue(forKey: requestID)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            fileWaiters.removeValue(forKey: requestID)
            throw error
        }
    }

    private func sendPlanAndAwaitResult(
        requestID: UUID,
        plan: SyncPlan,
        attachments: [BundledFile],
        peerName: String,
        transport: PeerTransport
    ) async throws -> ApplyResultMessage {
        do {
            return try await withTimeout("远端应用同步计划") {
                try await withCheckedThrowingContinuation { continuation in
                    self.applyWaiters[requestID] = continuation
                    do {
                        try transport.sendPayload(
                            PlanBundleMessage(requestID: requestID, plan: plan, attachments: attachments),
                            kind: .planBundle,
                            to: peerName
                        )
                    } catch {
                        self.applyWaiters.removeValue(forKey: requestID)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            applyWaiters.removeValue(forKey: requestID)
            throw error
        }
    }

    private func sendResolutionAndAwaitResult(
        message: ResolutionBundleMessage,
        peerName: String,
        transport: PeerTransport
    ) async throws -> ApplyResultMessage {
        do {
            return try await withTimeout("远端执行冲突决议") {
                try await withCheckedThrowingContinuation { continuation in
                    self.applyWaiters[message.requestID] = continuation
                    do {
                        try transport.sendPayload(message, kind: .resolutionBundle, to: peerName)
                    } catch {
                        self.applyWaiters.removeValue(forKey: message.requestID)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            applyWaiters.removeValue(forKey: message.requestID)
            throw error
        }
    }

    private func ensureRemoteBundle(
        for pending: PendingConflict,
        peerName: String,
        transport: PeerTransport
    ) async throws -> BundledFile? {
        guard let responderState = pending.conflict.responderState else {
            return nil
        }

        if let url = pending.remotePreviewURL, let data = try? Data(contentsOf: url) {
            return BundledFile(path: pending.conflict.path, fingerprint: responderState, data: data)
        }

        let bundleMessage = try await requestFiles(
            requestID: UUID(),
            files: [RequestedFile(path: pending.conflict.path, expectedState: responderState)],
            peerName: peerName,
            transport: transport
        )
        if let file = bundleMessage.files.first {
            let previewURL = try? storage.storeRemotePreview(
                data: file.data,
                conflictID: pending.conflict.id,
                originalPath: pending.conflict.path
            )
            if let previewURL, let index = pendingConflicts.firstIndex(where: { $0.id == pending.id }) {
                pendingConflicts[index] = PendingConflict(
                    id: pending.id,
                    peerDeviceID: pending.peerDeviceID,
                    peerName: pending.peerName,
                    conflict: pending.conflict,
                    detectedAt: pending.detectedAt,
                    remotePreviewURL: previewURL
                )
            }
            return file
        }
        throw SyncControllerError.peerChanged(pending.conflict.path)
    }

    private func scanManifest(root: URL) async throws -> DirectoryManifest {
        let scanner = DirectoryScanner()
        return try await Task.detached(priority: .userInitiated) {
            try scanner.scan(root: root)
        }.value
    }

    private func currentState(for relativePath: String, root: URL) async throws -> FileFingerprint? {
        let scanner = DirectoryScanner()
        return try await Task.detached(priority: .userInitiated) {
            try scanner.currentState(root: root, relativePath: relativePath)
        }.value
    }

    private func withTimeout<T>(_ stage: String, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                throw SyncControllerError.timeout(stage)
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func addLog(_ text: String) {
        activityItems.insert(ActivityItem(timestamp: Date(), text: text), at: 0)
        if activityItems.count > 80 {
            activityItems.removeLast(activityItems.count - 80)
        }
    }

    private func clearConnectionState(message: String) {
        connectedPeerName = nil
        remoteHello = nil
        statusText = message
        addLog(message)

        let disconnectError = NSError(domain: AppConstants.appName, code: 99, userInfo: [NSLocalizedDescriptionKey: message])
        for waiter in manifestWaiters.values {
            waiter.resume(throwing: disconnectError)
        }
        for waiter in fileWaiters.values {
            waiter.resume(throwing: disconnectError)
        }
        for waiter in applyWaiters.values {
            waiter.resume(throwing: disconnectError)
        }
        manifestWaiters.removeAll()
        fileWaiters.removeAll()
        applyWaiters.removeAll()
    }
}

extension SyncTwinController: PeerTransportDelegate {
    func peerTransport(_ transport: PeerTransport, didUpdate discoveredPeers: [DiscoveredPeer]) {
        self.discoveredPeers = discoveredPeers
    }

    func peerTransport(_ transport: PeerTransport, didChange state: PeerConnectionState, for peerDisplayName: String) {
        switch state {
        case .notConnected:
            if connectedPeerName == peerDisplayName {
                clearConnectionState(message: "与 \(peerDisplayName) 的连接已断开。")
            }
        case .connecting:
            statusText = "正在与 \(peerDisplayName) 建立加密连接..."
            addLog(statusText)
        case .connected:
            connectedPeerName = peerDisplayName
            statusText = "已连接 \(peerDisplayName)，正在校验版本..."
            addLog(statusText)
            let hello = HelloMessage(
                deviceID: config.deviceID,
                deviceName: config.deviceName,
                appVersion: AppConstants.appVersion,
                protocolVersion: AppConstants.protocolVersion
            )
            do {
                try transport.sendPayload(hello, kind: .hello, to: peerDisplayName)
            } catch {
                statusText = "发送版本握手失败：\(error.localizedDescription)"
                addLog(statusText)
            }
        }
    }

    func peerTransport(_ transport: PeerTransport, didReceive data: Data, from peerDisplayName: String) {
        do {
            let envelope = try SyncMessageCodec.decodeEnvelope(from: data)

            switch envelope.kind {
            case .hello:
                let message = try SyncMessageCodec.decodePayload(HelloMessage.self, from: envelope)
                remoteHello = message
                if let versionGateMessage {
                    statusText = versionGateMessage
                } else {
                    statusText = "已完成版本校验，可以开始同步。"
                }
                addLog("收到 \(message.deviceName) 的握手信息。")

            case .syncOffer:
                let message = try SyncMessageCodec.decodePayload(SyncOfferMessage.self, from: envelope)
                Task {
                    await handleSyncOffer(message, from: peerDisplayName)
                }

            case .syncManifest:
                let message = try SyncMessageCodec.decodePayload(SyncManifestMessage.self, from: envelope)
                manifestWaiters.removeValue(forKey: message.requestID)?.resume(returning: message)

            case .fileRequest:
                let message = try SyncMessageCodec.decodePayload(FileRequestMessage.self, from: envelope)
                Task {
                    await handleFileRequest(message, from: peerDisplayName)
                }

            case .fileBundle:
                let message = try SyncMessageCodec.decodePayload(FileBundleMessage.self, from: envelope)
                fileWaiters.removeValue(forKey: message.requestID)?.resume(returning: message)

            case .planBundle:
                let message = try SyncMessageCodec.decodePayload(PlanBundleMessage.self, from: envelope)
                Task {
                    await handlePlanBundle(message, from: peerDisplayName)
                }

            case .applyResult:
                let message = try SyncMessageCodec.decodePayload(ApplyResultMessage.self, from: envelope)
                applyWaiters.removeValue(forKey: message.requestID)?.resume(returning: message)

            case .commitBaseline:
                let message = try SyncMessageCodec.decodePayload(CommitBaselineMessage.self, from: envelope)
                handleCommitBaseline(message)

            case .resolutionBundle:
                let message = try SyncMessageCodec.decodePayload(ResolutionBundleMessage.self, from: envelope)
                Task {
                    await handleResolutionBundle(message, from: peerDisplayName)
                }

            case .syncError:
                let message = try SyncMessageCodec.decodePayload(SyncErrorMessage.self, from: envelope)
                handleSyncError(message)
            }
        } catch {
            statusText = "收到无法解析的消息：\(error.localizedDescription)"
            addLog(statusText)
        }
    }

    func peerTransport(_ transport: PeerTransport, didReport errorMessage: String) {
        statusText = errorMessage
        addLog(errorMessage)
    }
}

extension SyncTwinController {
    private func handleSyncOffer(_ message: SyncOfferMessage, from peerName: String) async {
        guard let transport else {
            return
        }
        guard let root = watchedFolderURL else {
            try? transport.sendPayload(
                SyncErrorMessage(requestID: message.requestID, message: SyncControllerError.noFolderConfigured.localizedDescription),
                kind: .syncError,
                to: peerName
            )
            return
        }
        guard let remoteHello else {
            try? transport.sendPayload(
                SyncErrorMessage(requestID: message.requestID, message: "握手尚未完成。"),
                kind: .syncError,
                to: peerName
            )
            return
        }
        if let versionGateMessage {
            try? transport.sendPayload(
                SyncErrorMessage(requestID: message.requestID, message: versionGateMessage),
                kind: .syncError,
                to: peerName
            )
            return
        }

        do {
            let localBaseline = storage.loadBaseline(for: remoteHello.deviceID)
            let localDigest = SyncStateDigest.digest(for: localBaseline)
            guard localDigest == message.baselineDigest else {
                throw SyncControllerError.baselineMismatch
            }

            let manifest = try await scanManifest(root: root)
            try transport.sendPayload(
                SyncManifestMessage(requestID: message.requestID, baselineDigest: localDigest, manifest: manifest),
                kind: .syncManifest,
                to: peerName
            )
            statusText = "已向 \(peerName) 发送本地目录清单。"
            addLog(statusText)
        } catch {
            try? transport.sendPayload(
                SyncErrorMessage(requestID: message.requestID, message: error.localizedDescription),
                kind: .syncError,
                to: peerName
            )
        }
    }

    private func handleFileRequest(_ message: FileRequestMessage, from peerName: String) async {
        guard let transport, let root = watchedFolderURL else {
            return
        }

        let scanner = DirectoryScanner()
        let response = await Task.detached(priority: .utility) {
            var files: [BundledFile] = []
            var failures: [ApplyFailure] = []

            for request in message.files {
                do {
                    let current = try scanner.currentState(root: root, relativePath: request.path)
                    guard equivalentState(current, request.expectedState) else {
                        failures.append(ApplyFailure(path: request.path, message: "文件在发送前已变化。"))
                        continue
                    }
                    let file = try scanner.bundleFile(root: root, relativePath: request.path, expectedState: request.expectedState)
                    files.append(file)
                } catch {
                    failures.append(ApplyFailure(path: request.path, message: error.localizedDescription))
                }
            }

            return FileBundleMessage(requestID: message.requestID, files: files, failures: failures)
        }.value

        try? transport.sendPayload(response, kind: .fileBundle, to: peerName)
    }

    private func handlePlanBundle(_ message: PlanBundleMessage, from peerName: String) async {
        guard let transport, let root = watchedFolderURL else {
            return
        }

        isSyncInProgress = true
        defer {
            isSyncInProgress = false
        }

        let filesByPath = Dictionary(uniqueKeysWithValues: message.attachments.map { ($0.path, $0) })
        do {
            let failures = try await applyOperations(
                message.plan.operations.filter { $0.target == .responder },
                on: root,
                localRole: .responder,
                remoteFilesByPath: filesByPath
            )

            let result = ApplyResultMessage(
                requestID: message.requestID,
                failures: failures,
                note: failures.isEmpty ? "远端变更已应用。" : "远端变更部分应用。"
            )
            try transport.sendPayload(result, kind: .applyResult, to: peerName)

            if !message.plan.conflicts.isEmpty {
                statusText = "对端发现 \(message.plan.conflicts.count) 个冲突，等待对端人工判断。"
            } else if failures.isEmpty {
                statusText = "已应用来自 \(peerName) 的同步计划。"
            } else {
                statusText = "应用来自 \(peerName) 的同步计划时发生 \(failures.count) 处失败。"
            }
            addLog(statusText)
        } catch {
            try? transport.sendPayload(
                ApplyResultMessage(
                    requestID: message.requestID,
                    failures: [ApplyFailure(path: "/", message: error.localizedDescription)],
                    note: "远端变更应用失败。"
                ),
                kind: .applyResult,
                to: peerName
            )
        }
    }

    private func handleResolutionBundle(_ message: ResolutionBundleMessage, from peerName: String) async {
        guard let transport, let root = watchedFolderURL else {
            return
        }

        isSyncInProgress = true
        defer {
            isSyncInProgress = false
        }

        let scanner = DirectoryScanner()
        let failures = await Task.detached(priority: .userInitiated) {
            var failures: [ApplyFailure] = []

            do {
                let current = try scanner.currentState(root: root, relativePath: message.conflict.path)
                guard equivalentState(current, message.conflict.responderState) else {
                    return [ApplyFailure(path: message.conflict.path, message: "对端冲突处理前，本机文件已变化。")]
                }

                if message.winningSide == .initiator {
                    if let backupPath = message.backupPath, let responderState = message.conflict.responderState {
                        do {
                            let localFile = try scanner.bundleFile(root: root, relativePath: message.conflict.path, expectedState: responderState)
                            try scanner.writeData(localFile.data, to: root, relativePath: backupPath, modifiedAt: localFile.fingerprint.modifiedAt)
                        } catch {
                            failures.append(ApplyFailure(path: backupPath, message: error.localizedDescription))
                        }
                    }

                    if let winnerAttachment = message.winnerAttachment {
                        do {
                            try scanner.writeData(
                                winnerAttachment.data,
                                to: root,
                                relativePath: message.conflict.path,
                                modifiedAt: winnerAttachment.fingerprint.modifiedAt
                            )
                        } catch {
                            failures.append(ApplyFailure(path: message.conflict.path, message: error.localizedDescription))
                        }
                    } else {
                        do {
                            try scanner.deleteItem(root: root, relativePath: message.conflict.path)
                        } catch {
                            failures.append(ApplyFailure(path: message.conflict.path, message: error.localizedDescription))
                        }
                    }
                } else {
                    if let backupPath = message.backupPath, let loserAttachment = message.loserAttachment {
                        do {
                            try scanner.writeData(
                                loserAttachment.data,
                                to: root,
                                relativePath: backupPath,
                                modifiedAt: loserAttachment.fingerprint.modifiedAt
                            )
                        } catch {
                            failures.append(ApplyFailure(path: backupPath, message: error.localizedDescription))
                        }
                    }

                    if message.conflict.responderState == nil {
                        do {
                            try scanner.deleteItem(root: root, relativePath: message.conflict.path)
                        } catch {
                            failures.append(ApplyFailure(path: message.conflict.path, message: error.localizedDescription))
                        }
                    }
                }

                return failures
            } catch {
                return [ApplyFailure(path: message.conflict.path, message: error.localizedDescription)]
            }
        }.value

        try? transport.sendPayload(
            ApplyResultMessage(
                requestID: message.requestID,
                failures: failures,
                note: failures.isEmpty ? "冲突决议已应用。" : "冲突决议部分应用失败。"
            ),
            kind: .applyResult,
            to: peerName
        )
    }

    private func handleCommitBaseline(_ message: CommitBaselineMessage) {
        guard let remoteHello else {
            return
        }
        do {
            var baseline = storage.loadBaseline(for: remoteHello.deviceID)
            updateBaseline(&baseline, with: message.changes)
            try storage.saveBaseline(baseline, for: remoteHello.deviceID)
            addLog("已提交 \(message.changes.count) 条同步基线更新。")
        } catch {
            statusText = "保存同步基线失败：\(error.localizedDescription)"
            addLog(statusText)
        }
    }

    private func handleSyncError(_ message: SyncErrorMessage) {
        let error = NSError(domain: AppConstants.appName, code: 401, userInfo: [NSLocalizedDescriptionKey: message.message])
        if let requestID = message.requestID {
            if let waiter = manifestWaiters.removeValue(forKey: requestID) {
                waiter.resume(throwing: error)
                return
            }
            if let waiter = fileWaiters.removeValue(forKey: requestID) {
                waiter.resume(throwing: error)
                return
            }
            if let waiter = applyWaiters.removeValue(forKey: requestID) {
                waiter.resume(throwing: error)
                return
            }
        }
        statusText = message.message
        addLog(message.message)
    }
}
