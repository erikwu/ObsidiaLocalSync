import AppKit
import Foundation

private enum ActiveSyncSession {
    case awaitingPermission(requestID: UUID, trigger: SyncTriggerLabel, peerDeviceID: String)
    case initiating(requestID: UUID, trigger: SyncTriggerLabel, peerDeviceID: String)
    case responding(requestID: UUID, trigger: SyncTriggerLabel, peerDeviceID: String)

    var requestID: UUID {
        switch self {
        case let .awaitingPermission(requestID, _, _),
             let .initiating(requestID, _, _),
             let .responding(requestID, _, _):
            return requestID
        }
    }

    var peerDeviceID: String {
        switch self {
        case let .awaitingPermission(_, _, peerDeviceID),
             let .initiating(_, _, peerDeviceID),
             let .responding(_, _, peerDeviceID):
            return peerDeviceID
        }
    }

    var trigger: SyncTriggerLabel {
        switch self {
        case let .awaitingPermission(_, trigger, _),
             let .initiating(_, trigger, _),
             let .responding(_, trigger, _):
            return trigger
        }
    }
}

enum SyncControllerError: LocalizedError {
    case transportUnavailable
    case noConnectedPeer
    case noFolderConfigured
    case versionMismatch(String)
    case baselineMismatch
    case syncRejected(String)
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
        case let .syncRejected(message):
            return message
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
    @Published var syncProgress: SyncProgressSnapshot?
    @Published var pendingConflicts: [PendingConflict] = []
    @Published var activityItems: [ActivityItem] = []

    private let storage = AppStorage.shared
    private let scanner = DirectoryScanner()
    private let planner = SyncPlanner()

    private var transport: PeerTransport?
    private var autoSyncTask: Task<Void, Never>?
    private var progressResetTask: Task<Void, Never>?
    private var activeSession: ActiveSyncSession? {
        didSet {
            isSyncInProgress = activeSession != nil
        }
    }

    private var intentWaiters: [UUID: CheckedContinuation<SyncIntentResponseMessage, Error>] = [:]
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
        progressResetTask?.cancel()
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

    private struct SyncExecutionContext {
        let requestID: UUID
        let trigger: SyncTriggerLabel
        let peerName: String
        let peerHello: HelloMessage
        let root: URL
        let transport: PeerTransport
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
        do {
            let context = try prepareSyncExecutionContext(trigger: trigger)
            Task {
                await performSync(using: context)
            }
        } catch {
            statusText = error.localizedDescription
            addLog(statusText)
        }
    }

    private func performSync(using context: SyncExecutionContext) async {
        statusText = "\(context.trigger.rawValue)中..."
        addLog("开始\(context.trigger.rawValue)，目标：\(context.peerName)。")
        updateSyncProgress(
            0.05,
            phase: "正在申请同步会话",
            detail: "等待 \(context.peerName) 确认本次\(context.trigger.rawValue)。"
        )

        defer {
            releaseActiveSessionIfMatches(context.requestID)
        }

        do {
            let intentResponse = try await requestSyncPermission(
                requestID: context.requestID,
                trigger: context.trigger,
                peerName: context.peerName,
                transport: context.transport
            )
            guard intentResponse.accepted else {
                throw SyncControllerError.syncRejected(intentResponse.message)
            }
            promoteToInitiatingSession(
                requestID: context.requestID,
                trigger: context.trigger,
                peerDeviceID: context.peerHello.deviceID
            )
            updateSyncProgress(
                0.14,
                phase: "正在扫描本机目录",
                detail: "正在读取本地目录状态，准备比较两边的改动。"
            )

            let baseline = storage.loadBaseline(for: context.peerHello.deviceID)
            let localManifest = try await scanManifest(root: context.root)
            let baselineDigest = SyncStateDigest.digest(for: baseline)
            updateSyncProgress(
                0.26,
                phase: "正在交换目录清单",
                detail: "等待 \(context.peerName) 返回目录摘要。"
            )

            let manifestMessage = try await requestRemoteManifest(
                requestID: context.requestID,
                baselineDigest: baselineDigest,
                localManifest: localManifest,
                peerName: context.peerName,
                transport: context.transport
            )

            guard manifestMessage.baselineDigest == baselineDigest else {
                throw SyncControllerError.baselineMismatch
            }

            updateSyncProgress(
                0.36,
                phase: "正在生成同步计划",
                detail: "正在比较两台电脑的新增、修改和删除。"
            )
            let plan = planner.makePlan(
                requestID: context.requestID,
                baseline: baseline,
                initiator: localManifest.files,
                responder: manifestMessage.manifest.files
            )

            let requestedRemoteFiles = uniqueRequestedFiles(from: plan)
            updateSyncProgress(
                0.48,
                phase: "正在收集对端文件",
                detail: requestedRemoteFiles.isEmpty
                    ? "本次没有需要从 \(context.peerName) 拉取的文件。"
                    : "正在从 \(context.peerName) 获取 \(requestedRemoteFiles.count) 个文件。"
            )
            let remoteBundleMessage = try await requestFiles(
                requestID: context.requestID,
                files: requestedRemoteFiles,
                peerName: context.peerName,
                transport: context.transport
            )
            let remoteFilesByPath = Dictionary(uniqueKeysWithValues: remoteBundleMessage.files.map { ($0.path, $0) })

            let localOperations = plan.operations.filter { $0.target == .initiator }
            let remoteOperations = plan.operations.filter { $0.target == .responder }
            let localAttachmentBuild = buildLocalAttachments(
                for: remoteOperations.filter { $0.source == .initiator },
                root: context.root
            )
            updateSyncProgress(
                0.62,
                phase: "正在准备应用变更",
                detail: remoteOperations.isEmpty
                    ? "本次不需要向 \(context.peerName) 发送文件。"
                    : "将向 \(context.peerName) 发送 \(localAttachmentBuild.files.count) 个文件，并应用 \(remoteOperations.count) 项变更。"
            )

            let remoteApplyTask = Task {
                try await self.sendPlanAndAwaitResult(
                    requestID: context.requestID,
                    plan: plan,
                    attachments: localAttachmentBuild.files,
                    peerName: context.peerName,
                    transport: context.transport
                )
            }

            updateSyncProgress(
                localOperations.isEmpty ? 0.74 : 0.68,
                phase: "正在更新本机文件",
                detail: localOperations.isEmpty
                    ? "本机没有需要写入的变更，正在等待对端处理。"
                    : "本机正在处理 \(localOperations.count) 项变更。"
            )
            let localFailures = try await applyOperations(
                localOperations,
                on: context.root,
                localRole: .initiator,
                remoteFilesByPath: remoteFilesByPath
            )

            updateSyncProgress(
                0.82,
                phase: "等待对端完成",
                detail: remoteOperations.isEmpty
                    ? "\(context.peerName) 正在确认同步结果。"
                    : "\(context.peerName) 正在应用 \(remoteOperations.count) 项变更。"
            )
            let remoteApplyResult = try await remoteApplyTask.value

            let failurePaths = Set(
                remoteBundleMessage.failures.map(\.path)
                    + localAttachmentBuild.failures.map(\.path)
                    + localFailures.map(\.path)
                    + remoteApplyResult.failures.map(\.path)
            )

            let commitChanges = plan.baselineChanges.filter { !failurePaths.contains($0.path) }
            var updatedBaseline = baseline
            updateBaseline(&updatedBaseline, with: commitChanges)
            updateSyncProgress(
                0.92,
                phase: "正在提交同步结果",
                detail: "正在把最新同步基线写回两台电脑。"
            )
            try storage.saveBaseline(updatedBaseline, for: context.peerHello.deviceID)
            try context.transport.sendPayload(
                CommitBaselineMessage(requestID: context.requestID, changes: commitChanges),
                kind: .commitBaseline,
                to: context.peerName
            )

            registerPendingConflicts(plan.conflicts, remoteFilesByPath: remoteFilesByPath, peerHello: context.peerHello)

            if !plan.conflicts.isEmpty {
                statusText = "安全变更已自动同步，另有 \(plan.conflicts.count) 个冲突等待人工判断。"
            } else if !failurePaths.isEmpty {
                statusText = "同步部分完成，\(failurePaths.count) 个文件需要重试。"
            } else {
                statusText = "同步完成，没有发生内容丢失。"
            }
            completeSyncProgress(phase: "同步完成", detail: statusText)
            addLog(statusText)
            playCompletionSoundIfNeeded(for: context.trigger)
        } catch {
            if ownsLocalSession(requestID: context.requestID) {
                try? context.transport.sendPayload(
                    SyncErrorMessage(requestID: context.requestID, message: error.localizedDescription),
                    kind: .syncError,
                    to: context.peerName
                )
            }
            clearSyncProgress()
            statusText = error.localizedDescription
            addLog(statusText)
        }
    }

    private func prepareSyncExecutionContext(trigger: SyncTriggerLabel) throws -> SyncExecutionContext {
        guard activeSession == nil else {
            throw SyncControllerError.syncRejected("已有同步任务正在进行中。")
        }
        guard let peerName = connectedPeerName, let peerHello = remoteHello else {
            throw SyncControllerError.noConnectedPeer
        }
        if let versionGateMessage {
            throw SyncControllerError.versionMismatch(versionGateMessage)
        }
        guard let root = watchedFolderURL else {
            throw SyncControllerError.noFolderConfigured
        }
        guard let transport else {
            throw SyncControllerError.transportUnavailable
        }

        let requestID = UUID()
        activeSession = .awaitingPermission(
            requestID: requestID,
            trigger: trigger,
            peerDeviceID: peerHello.deviceID
        )

        return SyncExecutionContext(
            requestID: requestID,
            trigger: trigger,
            peerName: peerName,
            peerHello: peerHello,
            root: root,
            transport: transport
        )
    }

    private func promoteToInitiatingSession(
        requestID: UUID,
        trigger: SyncTriggerLabel,
        peerDeviceID: String
    ) {
        guard activeSession?.requestID == requestID else {
            return
        }
        activeSession = .initiating(
            requestID: requestID,
            trigger: trigger,
            peerDeviceID: peerDeviceID
        )
    }

    private func releaseActiveSessionIfMatches(_ requestID: UUID) {
        guard activeSession?.requestID == requestID else {
            return
        }
        activeSession = nil
    }

    private func ownsLocalSession(requestID: UUID) -> Bool {
        switch activeSession {
        case let .awaitingPermission(activeRequestID, _, _),
             let .initiating(activeRequestID, _, _):
            return activeRequestID == requestID
        default:
            return false
        }
    }

    private func isResponderSession(requestID: UUID) -> Bool {
        if case let .responding(activeRequestID, _, _) = activeSession {
            return activeRequestID == requestID
        }
        return false
    }

    private func triggerForSession(requestID: UUID) -> SyncTriggerLabel? {
        guard let activeSession, activeSession.requestID == requestID else {
            return nil
        }
        return activeSession.trigger
    }

    private func shouldRemoteIntentWin(
        localTrigger: SyncTriggerLabel,
        remoteTrigger: SyncTriggerLabel,
        remoteDeviceID: String
    ) -> Bool {
        if remoteTrigger.priority != localTrigger.priority {
            return remoteTrigger.priority > localTrigger.priority
        }
        return remoteDeviceID < config.deviceID
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
        updateSyncProgress(
            0.08,
            phase: "正在准备冲突决议",
            detail: "正在校验 \(pending.conflict.path) 的最新状态。"
        )

        defer {
            isSyncInProgress = false
        }

        do {
            let currentLocalState = try await currentState(for: pending.conflict.path, root: root)
            guard equivalentState(currentLocalState, pending.conflict.initiatorState) else {
                throw SyncControllerError.localStateChanged(pending.conflict.path)
            }

            updateSyncProgress(
                0.28,
                phase: "正在获取对端快照",
                detail: "正在确认对端版本仍然是待处理的冲突内容。"
            )
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

            updateSyncProgress(
                0.52,
                phase: "正在应用本机决议",
                detail: "正在把你的选择应用到两台电脑。"
            )
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

            updateSyncProgress(
                0.78,
                phase: "等待对端确认决议",
                detail: "正在等待 \(peerName) 完成同一份冲突决议。"
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
                completeSyncProgress(phase: "冲突处理部分完成", detail: statusText)
                addLog(statusText)
                playCompletionSoundIfNeeded(for: .manual)
                return
            }

            let baseline = storage.loadBaseline(for: peerHello.deviceID)
            var updatedBaseline = baseline
            updateBaseline(&updatedBaseline, with: baselineChanges)
            updateSyncProgress(
                0.92,
                phase: "正在提交冲突结果",
                detail: "正在更新两台电脑的同步基线。"
            )
            try storage.saveBaseline(updatedBaseline, for: peerHello.deviceID)
            try transport.sendPayload(
                CommitBaselineMessage(requestID: requestID, changes: baselineChanges),
                kind: .commitBaseline,
                to: peerName
            )

            pendingConflicts.removeAll { $0.id == pending.id }
            statusText = "冲突已处理，未选中的版本已保留为冲突副本。"
            completeSyncProgress(phase: "冲突已处理", detail: statusText)
            addLog(statusText)
            playCompletionSoundIfNeeded(for: .manual)
        } catch {
            clearSyncProgress()
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

    private func requestSyncPermission(
        requestID: UUID,
        trigger: SyncTriggerLabel,
        peerName: String,
        transport: PeerTransport
    ) async throws -> SyncIntentResponseMessage {
        do {
            return try await withTimeout("同步会话握手") {
                try await withCheckedThrowingContinuation { continuation in
                    self.intentWaiters[requestID] = continuation
                    do {
                        try transport.sendPayload(
                            SyncIntentMessage(
                                requestID: requestID,
                                initiatorDeviceID: self.config.deviceID,
                                trigger: trigger
                            ),
                            kind: .syncIntent,
                            to: peerName
                        )
                    } catch {
                        self.intentWaiters.removeValue(forKey: requestID)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            intentWaiters.removeValue(forKey: requestID)
            throw error
        }
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

    private func playCompletionSound() {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func playCompletionSoundIfNeeded(for trigger: SyncTriggerLabel?) {
        guard let trigger else {
            return
        }

        switch trigger {
        case .manual:
            playCompletionSound()
        case .automatic:
            guard config.autoSyncCompletionSoundEnabled else {
                return
            }
            playCompletionSound()
        }
    }

    private func updateSyncProgress(_ fraction: Double, phase: String, detail: String) {
        progressResetTask?.cancel()
        progressResetTask = nil
        syncProgress = SyncProgressSnapshot(
            phase: phase,
            detail: detail,
            fractionCompleted: fraction
        )
    }

    private func completeSyncProgress(phase: String, detail: String) {
        progressResetTask?.cancel()
        syncProgress = SyncProgressSnapshot(
            phase: phase,
            detail: detail,
            fractionCompleted: 1
        )
        progressResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                guard let self, !self.isSyncInProgress else {
                    return
                }
                self.syncProgress = nil
                self.progressResetTask = nil
            }
        }
    }

    private func clearSyncProgress() {
        progressResetTask?.cancel()
        progressResetTask = nil
        syncProgress = nil
    }

    private func resetSessionStateIfMatches(_ requestID: UUID) {
        if activeSession?.requestID == requestID {
            clearSyncProgress()
        }
        releaseActiveSessionIfMatches(requestID)
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
        clearSyncProgress()
        statusText = message
        addLog(message)

        let disconnectError = NSError(domain: AppConstants.appName, code: 99, userInfo: [NSLocalizedDescriptionKey: message])
        for waiter in intentWaiters.values {
            waiter.resume(throwing: disconnectError)
        }
        for waiter in manifestWaiters.values {
            waiter.resume(throwing: disconnectError)
        }
        for waiter in fileWaiters.values {
            waiter.resume(throwing: disconnectError)
        }
        for waiter in applyWaiters.values {
            waiter.resume(throwing: disconnectError)
        }
        intentWaiters.removeAll()
        manifestWaiters.removeAll()
        fileWaiters.removeAll()
        applyWaiters.removeAll()
        activeSession = nil
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

            case .syncIntent:
                let message = try SyncMessageCodec.decodePayload(SyncIntentMessage.self, from: envelope)
                Task {
                    await handleSyncIntent(message, from: peerDisplayName)
                }

            case .syncIntentResponse:
                let message = try SyncMessageCodec.decodePayload(SyncIntentResponseMessage.self, from: envelope)
                intentWaiters.removeValue(forKey: message.requestID)?.resume(returning: message)

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
    private func handleSyncIntent(_ message: SyncIntentMessage, from peerName: String) async {
        guard let transport else {
            return
        }

        let response: SyncIntentResponseMessage

        if watchedFolderURL == nil {
            response = SyncIntentResponseMessage(
                requestID: message.requestID,
                accepted: false,
                message: SyncControllerError.noFolderConfigured.localizedDescription
            )
        } else if remoteHello == nil {
            response = SyncIntentResponseMessage(
                requestID: message.requestID,
                accepted: false,
                message: "版本握手尚未完成，当前无法开始同步。"
            )
        } else if let versionGateMessage {
            response = SyncIntentResponseMessage(
                requestID: message.requestID,
                accepted: false,
                message: versionGateMessage
            )
        } else {
            switch activeSession {
            case .none:
                activeSession = .responding(
                    requestID: message.requestID,
                    trigger: message.trigger,
                    peerDeviceID: message.initiatorDeviceID
                )
                response = SyncIntentResponseMessage(
                    requestID: message.requestID,
                    accepted: true,
                    message: "同步会话已授权。"
                )

            case let .awaitingPermission(localRequestID, localTrigger, _):
                if shouldRemoteIntentWin(
                    localTrigger: localTrigger,
                    remoteTrigger: message.trigger,
                    remoteDeviceID: message.initiatorDeviceID
                ) {
                    intentWaiters.removeValue(forKey: localRequestID)?.resume(
                        returning: SyncIntentResponseMessage(
                            requestID: localRequestID,
                            accepted: false,
                            message: "另一台电脑的同步请求已优先执行，本次请求已自动让路。"
                        )
                    )
                    activeSession = .responding(
                        requestID: message.requestID,
                        trigger: message.trigger,
                        peerDeviceID: message.initiatorDeviceID
                    )
                    response = SyncIntentResponseMessage(
                        requestID: message.requestID,
                        accepted: true,
                        message: "同步会话已授权。"
                    )
                } else {
                    response = SyncIntentResponseMessage(
                        requestID: message.requestID,
                        accepted: false,
                        message: "本机当前同步请求优先级更高，请等待本次同步结束后再试。"
                    )
                }

            case let .responding(activeRequestID, _, peerDeviceID)
                where activeRequestID == message.requestID && peerDeviceID == message.initiatorDeviceID:
                response = SyncIntentResponseMessage(
                    requestID: message.requestID,
                    accepted: true,
                    message: "同步会话已授权。"
                )

            case .responding, .initiating:
                response = SyncIntentResponseMessage(
                    requestID: message.requestID,
                    accepted: false,
                    message: "另一台电脑当前已有同步任务正在进行中。"
                )
            }
        }

        try? transport.sendPayload(response, kind: .syncIntentResponse, to: peerName)
        if response.accepted {
            updateSyncProgress(
                0.05,
                phase: "同步会话已建立",
                detail: "\(peerName) 发起了\(message.trigger.rawValue)，正在等待目录清单。"
            )
        }
    }

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
            resetSessionStateIfMatches(message.requestID)
            return
        }
        guard let remoteHello else {
            try? transport.sendPayload(
                SyncErrorMessage(requestID: message.requestID, message: "握手尚未完成。"),
                kind: .syncError,
                to: peerName
            )
            resetSessionStateIfMatches(message.requestID)
            return
        }
        if let versionGateMessage {
            try? transport.sendPayload(
                SyncErrorMessage(requestID: message.requestID, message: versionGateMessage),
                kind: .syncError,
                to: peerName
            )
            resetSessionStateIfMatches(message.requestID)
            return
        }
        guard isResponderSession(requestID: message.requestID) else {
            try? transport.sendPayload(
                SyncErrorMessage(
                    requestID: message.requestID,
                    message: "未建立有效的同步会话，已拒绝此次同步请求。"
                ),
                kind: .syncError,
                to: peerName
            )
            return
        }

        do {
            updateSyncProgress(
                0.18,
                phase: "正在扫描本机目录",
                detail: "正在为 \(peerName) 准备本地目录清单。"
            )
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
            updateSyncProgress(
                0.32,
                phase: "目录清单已发送",
                detail: "已将本地目录摘要发给 \(peerName)，等待对端生成同步计划。"
            )
            statusText = "已向 \(peerName) 发送本地目录清单。"
            addLog(statusText)
        } catch {
            try? transport.sendPayload(
                SyncErrorMessage(requestID: message.requestID, message: error.localizedDescription),
                kind: .syncError,
                to: peerName
            )
            resetSessionStateIfMatches(message.requestID)
        }
    }

    private func handleFileRequest(_ message: FileRequestMessage, from peerName: String) async {
        guard let transport, let root = watchedFolderURL else {
            return
        }
        guard isResponderSession(requestID: message.requestID) else {
            try? transport.sendPayload(
                SyncErrorMessage(
                    requestID: message.requestID,
                    message: "未建立有效的同步会话，已拒绝此次文件请求。"
                ),
                kind: .syncError,
                to: peerName
            )
            return
        }

        updateSyncProgress(
            0.46,
            phase: "正在准备同步文件",
            detail: "正在整理 \(message.files.count) 个文件发送给 \(peerName)。"
        )
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
        updateSyncProgress(
            0.58,
            phase: "文件已发送",
            detail: "已向 \(peerName) 发送 \(response.files.count) 个文件，等待对端应用同步计划。"
        )
    }

    private func handlePlanBundle(_ message: PlanBundleMessage, from peerName: String) async {
        guard let transport, let root = watchedFolderURL else {
            return
        }
        guard isResponderSession(requestID: message.requestID) else {
            try? transport.sendPayload(
                ApplyResultMessage(
                    requestID: message.requestID,
                    failures: [ApplyFailure(path: "/", message: "未建立有效的同步会话，已拒绝应用此次同步计划。")],
                    note: "同步计划被拒绝。"
                ),
                kind: .applyResult,
                to: peerName
            )
            return
        }

        let responderOperations = message.plan.operations.filter { $0.target == .responder }
        let filesByPath = Dictionary(uniqueKeysWithValues: message.attachments.map { ($0.path, $0) })
        updateSyncProgress(
            0.72,
            phase: "正在应用对端变更",
            detail: responderOperations.isEmpty
                ? "本机没有需要写入的变更，正在确认结果。"
                : "正在处理来自 \(peerName) 的 \(responderOperations.count) 项变更。"
        )
        do {
            let failures = try await applyOperations(
                responderOperations,
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
            updateSyncProgress(
                0.90,
                phase: failures.isEmpty ? "正在等待最终确认" : "已返回处理结果",
                detail: statusText
            )
            addLog(statusText)
            playCompletionSoundIfNeeded(for: triggerForSession(requestID: message.requestID))
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
            resetSessionStateIfMatches(message.requestID)
            clearSyncProgress()
        }
    }

    private func handleResolutionBundle(_ message: ResolutionBundleMessage, from peerName: String) async {
        guard let transport, let root = watchedFolderURL else {
            return
        }

        isSyncInProgress = true
        updateSyncProgress(
            0.12,
            phase: "正在应用冲突决议",
            detail: "正在根据对方的选择更新 \(message.conflict.path)。"
        )
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

        updateSyncProgress(
            0.88,
            phase: failures.isEmpty ? "等待最终确认" : "冲突决议部分失败",
            detail: failures.isEmpty
                ? "冲突文件已更新，等待 \(peerName) 写回同步基线。"
                : "已把冲突处理结果返回给 \(peerName)。"
        )
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
        let shouldCompleteResponderProgress = isResponderSession(requestID: message.requestID)
        defer {
            releaseActiveSessionIfMatches(message.requestID)
        }
        do {
            var baseline = storage.loadBaseline(for: remoteHello.deviceID)
            updateBaseline(&baseline, with: message.changes)
            try storage.saveBaseline(baseline, for: remoteHello.deviceID)
            addLog("已提交 \(message.changes.count) 条同步基线更新。")
            if shouldCompleteResponderProgress {
                completeSyncProgress(
                    phase: "同步完成",
                    detail: "两台电脑都已确认本轮同步结果。"
                )
            }
        } catch {
            clearSyncProgress()
            statusText = "保存同步基线失败：\(error.localizedDescription)"
            addLog(statusText)
        }
    }

    private func handleSyncError(_ message: SyncErrorMessage) {
        let error = NSError(domain: AppConstants.appName, code: 401, userInfo: [NSLocalizedDescriptionKey: message.message])
        if let requestID = message.requestID {
            if let waiter = intentWaiters.removeValue(forKey: requestID) {
                waiter.resume(throwing: error)
                clearSyncProgress()
                releaseActiveSessionIfMatches(requestID)
                return
            }
            if let waiter = manifestWaiters.removeValue(forKey: requestID) {
                waiter.resume(throwing: error)
                clearSyncProgress()
                releaseActiveSessionIfMatches(requestID)
                return
            }
            if let waiter = fileWaiters.removeValue(forKey: requestID) {
                waiter.resume(throwing: error)
                clearSyncProgress()
                releaseActiveSessionIfMatches(requestID)
                return
            }
            if let waiter = applyWaiters.removeValue(forKey: requestID) {
                waiter.resume(throwing: error)
                clearSyncProgress()
                releaseActiveSessionIfMatches(requestID)
                return
            }
            clearSyncProgress()
            releaseActiveSessionIfMatches(requestID)
        }
        clearSyncProgress()
        statusText = message.message
        addLog(message.message)
    }
}
