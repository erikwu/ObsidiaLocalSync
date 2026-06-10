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

private enum OverallETAWorkBucket: CaseIterable {
    case handshake
    case localScan
    case remoteScan
    case planning
    case receiveFiles
    case sendFiles
    case applyLocalChanges
    case applyRemoteChanges
    case finalize
}

private struct OverallETAWorkState {
    var completed: Double = 0
    var total: Double = 0
}

private struct OverallSyncETAEstimate {
    let requestID: UUID
    let startedAt: Date
    var work: [OverallETAWorkBucket: OverallETAWorkState]

    init(requestID: UUID, startedAt: Date = Date()) {
        self.requestID = requestID
        self.startedAt = startedAt
        self.work = Dictionary(
            uniqueKeysWithValues: OverallETAWorkBucket.allCases.map { ($0, OverallETAWorkState()) }
        )
    }

    var overallFraction: Double? {
        let totalUnits = work.values.reduce(0) { $0 + $1.total }
        guard totalUnits > 0 else {
            return nil
        }

        let completedUnits = work.values.reduce(0) { $0 + min($1.completed, $1.total) }
        guard completedUnits > 0 else {
            return nil
        }
        let fraction = min(max(completedUnits / totalUnits, 0), 0.995)
        guard fraction >= 0.02 else {
            return nil
        }
        return fraction
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
    @Published var updateSnapshot = AppUpdateSnapshot.idle

    private let storage = AppStorage.shared
    private let scanner = DirectoryScanner()
    private let planner = SyncPlanner()
    private let updateService = GitHubReleaseUpdateService()
    private let changeMonitor = DirectoryChangeMonitor(storage: AppStorage.shared)

    private var transport: PeerTransport?
    private var autoSyncTask: Task<Void, Never>?
    private var progressResetTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var progressStartedAt: Date?
    private var overallETAEstimate: OverallSyncETAEstimate?
    private var activeSession: ActiveSyncSession? {
        didSet {
            isSyncInProgress = activeSession != nil
        }
    }

    private var intentWaiters: [UUID: CheckedContinuation<SyncIntentResponseMessage, Error>] = [:]
    private var manifestWaiters: [UUID: CheckedContinuation<SyncManifestMessage, Error>] = [:]
    private var fileWaiters: [UUID: CheckedContinuation<FileBundleMessage, Error>] = [:]
    private var applyWaiters: [UUID: CheckedContinuation<ApplyResultMessage, Error>] = [:]
    private var pendingLocalManifests: [UUID: [String: FileFingerprint]] = [:]
    private var incomingFileTransfers: [UUID: PendingIncomingFileTransfer] = [:]

    override init() {
        config = storage.loadConfiguration()
        super.init()
        storage.clearAllPreviewFiles()
        startTransport()
        restartChangeMonitor()
        scheduleAutoSyncLoop()
        addLog("应用已启动，版本 \(AppConstants.appVersion)。")
        startUpdateCheck(trigger: .automaticOnLaunch)
    }

    deinit {
        autoSyncTask?.cancel()
        progressResetTask?.cancel()
        updateTask?.cancel()
        changeMonitor.stop()
        transport?.stop()
    }

    var watchedFolderURL: URL? {
        guard !config.watchedFolderPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: canonicalDirectoryRootPath(config.watchedFolderPath), isDirectory: true)
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

    var canRevealDownloadedUpdate: Bool {
        guard let downloadedFileURL = updateSnapshot.downloadedFileURL else {
            return false
        }
        return FileManager.default.fileExists(atPath: downloadedFileURL.path)
    }

    var canOpenReleasePage: Bool {
        updateSnapshot.releasePageURL != nil
    }

    private struct SyncExecutionContext {
        let requestID: UUID
        let trigger: SyncTriggerLabel
        let peerName: String
        let peerHello: HelloMessage
        let root: URL
        let transport: PeerTransport
    }

    private struct IncomingTransferredFileState {
        let descriptor: TransferredFileDescriptor
        let temporaryURL: URL
        var receivedBytes: Int64 = 0
        var nextChunkIndex: Int = 0
        var expectedTotalChunks: Int? = nil
    }

    private struct PendingIncomingFileTransfer {
        let directoryURL: URL
        let failures: [ApplyFailure]
        let fileOrder: [String]
        var filesByPath: [String: IncomingTransferredFileState]
    }

    func pickFolder() {
        guard !isSyncInProgress else {
            statusText = "请等待当前同步结束后再切换同步目录。"
            addLog(statusText)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择目录"

        if panel.runModal() == .OK, let url = panel.url {
            let previousFolderPath = config.watchedFolderPath
            let selectedPath = canonicalDirectoryRootPath(url.path)
            config.watchedFolderPath = selectedPath
            saveSettings(
                previousWatchedFolderPath: previousFolderPath,
                forceResetSyncStateForCurrentFolder: !selectedPath.isEmpty
            )
        }
    }

    func saveSettings(
        previousWatchedFolderPath: String? = nil,
        forceResetSyncStateForCurrentFolder: Bool = false
    ) {
        let oldDisplayName = transport?.localPeerID.displayName
        let normalizedPreviousFolderPath = canonicalDirectoryRootPath(
            previousWatchedFolderPath ?? config.watchedFolderPath
        )

        config.deviceName = config.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.deviceName.isEmpty {
            config.deviceName = Host.current().localizedName ?? "Mac"
        }
        config.syncIntervalSeconds = max(60, config.syncIntervalSeconds)
        config.watchedFolderPath = canonicalDirectoryRootPath(config.watchedFolderPath)

        let folderChanged = normalizedPreviousFolderPath != config.watchedFolderPath
        let shouldResetSyncState = forceResetSyncStateForCurrentFolder || folderChanged

        do {
            try storage.saveConfiguration(config)
            addLog("设置已保存。")
            statusText = "设置已保存。"
        } catch {
            statusText = "保存设置失败：\(error.localizedDescription)"
            addLog(statusText)
        }

        if shouldResetSyncState, !config.watchedFolderPath.isEmpty {
            do {
                try storage.clearSyncState(rootPath: config.watchedFolderPath)
                pendingConflicts.removeAll()
                storage.clearAllPreviewFiles()
                addLog("已清除当前同步目录对应的历史基线与缓存，避免旧同步历史误用于当前目录。")
            } catch {
                let message = "清理当前同步目录的历史同步状态失败：\(error.localizedDescription)"
                statusText = message
                addLog(message)
            }
        }

        if oldDisplayName != config.deviceName {
            startTransport()
        }
        restartChangeMonitor()
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

    func checkForUpdatesManually() {
        startUpdateCheck(trigger: .manual)
    }

    func openReleasePage() {
        NSWorkspace.shared.open(updateSnapshot.releasePageURL ?? AppConstants.githubReleasesPageURL)
    }

    func revealDownloadedUpdate() {
        guard let downloadedFileURL = updateSnapshot.downloadedFileURL,
              FileManager.default.fileExists(atPath: downloadedFileURL.path) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([downloadedFileURL])
    }

    func startManualSync() {
        if promoteActiveSessionToManualIfNeeded() {
            return
        }
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

    private func restartChangeMonitor() {
        guard let watchedFolderURL else {
            changeMonitor.stop()
            return
        }
        changeMonitor.startMonitoring(root: watchedFolderURL)
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

    private func startUpdateCheck(trigger: UpdateCheckTrigger) {
        guard !updateSnapshot.isBusy else {
            return
        }

        updateTask?.cancel()
        updateTask = Task { [weak self] in
            await self?.performUpdateCheck(trigger: trigger)
        }
    }

    private func performUpdateCheck(trigger: UpdateCheckTrigger) async {
        let previousSnapshot = updateSnapshot
        updateSnapshot = AppUpdateSnapshot(
            phase: .checking,
            detail: trigger == .manual
                ? "正在检查 GitHub Release..."
                : "启动时正在检查 GitHub Release...",
            latestVersion: previousSnapshot.latestVersion,
            releasePageURL: previousSnapshot.releasePageURL ?? AppConstants.githubReleasesPageURL,
            downloadedFileURL: previousSnapshot.downloadedFileURL,
            lastCheckedAt: previousSnapshot.lastCheckedAt,
            assetName: previousSnapshot.assetName
        )

        if trigger == .manual {
            addLog("正在手工检查 GitHub Release 更新。")
        }

        do {
            let release = try await updateService.fetchLatestRelease()
            let currentVersion = VersionIdentifier(AppConstants.appVersion)
            let latestVersion = VersionIdentifier(release.tagName)
            let checkedAt = Date()

            guard latestVersion > currentVersion else {
                updateSnapshot = AppUpdateSnapshot(
                    phase: .upToDate,
                    detail: "当前已是最新版本。",
                    latestVersion: release.normalizedVersion,
                    releasePageURL: release.htmlURL,
                    downloadedFileURL: previousSnapshot.downloadedFileURL,
                    lastCheckedAt: checkedAt,
                    assetName: previousSnapshot.assetName
                )
                if trigger == .manual {
                    addLog("已确认当前版本就是最新 GitHub Release。")
                }
                return
            }

            guard let asset = release.preferredAsset else {
                let detail = "发现新版本 \(release.normalizedVersion)，但 release 中没有可自动下载的 macOS 安装包。"
                updateSnapshot = AppUpdateSnapshot(
                    phase: .updateAvailable,
                    detail: detail,
                    latestVersion: release.normalizedVersion,
                    releasePageURL: release.htmlURL,
                    downloadedFileURL: nil,
                    lastCheckedAt: checkedAt,
                    assetName: nil
                )
                addLog(detail)
                return
            }

            if let downloadedFileURL = storage.existingDownloadedUpdateURL(
                releaseTag: release.tagName,
                assetName: asset.name
            ) {
                let detail = "新版本 \(release.normalizedVersion) 已经下载到本机。"
                updateSnapshot = AppUpdateSnapshot(
                    phase: .downloaded,
                    detail: detail,
                    latestVersion: release.normalizedVersion,
                    releasePageURL: release.htmlURL,
                    downloadedFileURL: downloadedFileURL,
                    lastCheckedAt: checkedAt,
                    assetName: asset.name
                )
                if trigger == .manual {
                    addLog(detail)
                }
                return
            }

            let downloadingDetail = trigger == .manual
                ? "发现新版本 \(release.normalizedVersion)，正在下载 \(asset.name)。"
                : "启动时发现新版本 \(release.normalizedVersion)，正在自动下载 \(asset.name)。"
            updateSnapshot = AppUpdateSnapshot(
                phase: .downloading,
                detail: downloadingDetail,
                latestVersion: release.normalizedVersion,
                releasePageURL: release.htmlURL,
                downloadedFileURL: nil,
                lastCheckedAt: checkedAt,
                assetName: asset.name
            )
            addLog(downloadingDetail)

            let temporaryURL = try await updateService.downloadAsset(asset)
            let downloadedFileURL = try storage.storeDownloadedUpdate(
                from: temporaryURL,
                releaseTag: release.tagName,
                assetName: asset.name
            )

            let downloadedDetail = "新版本 \(release.normalizedVersion) 已下载完成。"
            updateSnapshot = AppUpdateSnapshot(
                phase: .downloaded,
                detail: downloadedDetail,
                latestVersion: release.normalizedVersion,
                releasePageURL: release.htmlURL,
                downloadedFileURL: downloadedFileURL,
                lastCheckedAt: checkedAt,
                assetName: asset.name
            )
            addLog("\(downloadedDetail) 文件：\(downloadedFileURL.lastPathComponent)。")
        } catch is CancellationError {
            return
        } catch {
            let detail: String
            switch trigger {
            case .automaticOnLaunch:
                detail = "自动检查更新失败，可稍后手动查看更新。"
            case .manual:
                detail = "检查更新失败：\(error.localizedDescription)"
            }

            updateSnapshot = AppUpdateSnapshot(
                phase: .failed,
                detail: detail,
                latestVersion: previousSnapshot.latestVersion,
                releasePageURL: previousSnapshot.releasePageURL ?? AppConstants.githubReleasesPageURL,
                downloadedFileURL: previousSnapshot.downloadedFileURL,
                lastCheckedAt: Date(),
                assetName: previousSnapshot.assetName
            )
            addLog(detail)
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
        startOverallETAEstimate(requestID: context.requestID)
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
            markETAWorkComplete(.handshake, total: 1, requestID: context.requestID)
            updateSyncProgress(
                0.14,
                phase: "正在扫描本机目录",
                detail: "正在读取本地目录状态，准备比较两边的改动。"
            )

            let baseline = storage.loadBaseline(for: context.peerHello.deviceID, rootPath: context.root.path)
            let estimatedLocalScanUnits = estimatedScanWorkUnitCount(
                root: context.root,
                peerDeviceID: context.peerHello.deviceID,
                baseline: baseline
            )
            setETAWork(
                .localScan,
                completed: 0,
                total: Double(estimatedLocalScanUnits),
                requestID: context.requestID
            )
            setETAWork(
                .remoteScan,
                completed: 0,
                total: Double(max(estimatedLocalScanUnits, baseline.count, 1)),
                requestID: context.requestID
            )
            let localScanResult = try await scanLocalState(
                root: context.root,
                baseline: baseline,
                peerDeviceID: context.peerHello.deviceID
            )
            markETAWorkComplete(
                .localScan,
                total: Double(max(estimatedLocalScanUnits, localScanResult.filesystemWorkUnits, 1)),
                requestID: context.requestID
            )
            pendingLocalManifests[context.requestID] = localScanResult.manifest.files
            let baselineDigest = SyncStateDigest.digest(for: baseline)
            updateSyncProgress(
                0.26,
                phase: "正在交换目录清单",
                detail: "等待 \(context.peerName) 返回目录摘要。"
            )

            let manifestMessage = try await requestRemoteManifest(
                requestID: context.requestID,
                baselineDigest: baselineDigest,
                localDelta: localScanResult.delta,
                peerName: context.peerName,
                transport: context.transport
            )

            guard manifestMessage.baselineDigest == baselineDigest else {
                throw SyncControllerError.baselineMismatch
            }

            markETAWorkComplete(
                .remoteScan,
                total: Double(
                    estimatedCurrentFileCount(
                        baseline: baseline,
                        delta: manifestMessage.delta,
                        fallback: localScanResult.manifest.files.count
                    )
                ),
                requestID: context.requestID
            )

            updateSyncProgress(
                0.36,
                phase: "正在生成同步计划",
                detail: "正在比较两台电脑的新增、修改和删除。"
            )
            let plan = planner.makePlan(
                requestID: context.requestID,
                baseline: baseline,
                initiatorDelta: localScanResult.delta,
                responderDelta: manifestMessage.delta
            )

            let requestedRemoteFiles = uniqueRequestedFiles(from: plan)
            let localOperations = plan.operations.filter { $0.target == .initiator }
            let remoteOperations = plan.operations.filter { $0.target == .responder }
            let remoteFilesToServeCount = requestedFiles(
                for: remoteOperations.filter { $0.source == .initiator }
            ).count
            setETAWork(
                .receiveFiles,
                completed: 0,
                total: Double(requestedRemoteFiles.count),
                requestID: context.requestID
            )
            setETAWork(
                .sendFiles,
                completed: 0,
                total: Double(remoteFilesToServeCount),
                requestID: context.requestID
            )
            setETAWork(
                .applyLocalChanges,
                completed: 0,
                total: Double(localOperations.count),
                requestID: context.requestID
            )
            setETAWork(
                .applyRemoteChanges,
                completed: 0,
                total: Double(remoteOperations.count),
                requestID: context.requestID
            )
            markETAWorkComplete(.planning, total: 1, requestID: context.requestID)
            updateSyncProgress(
                0.48,
                phase: "正在接收对端文件",
                detail: requestedRemoteFiles.isEmpty
                    ? "本次没有需要从 \(context.peerName) 拉取的文件。"
                    : "准备从 \(context.peerName) 获取 \(requestedRemoteFiles.count) 个文件。"
            )
            let remoteBundleMessage = try await requestFilesInBatches(
                requestID: context.requestID,
                files: requestedRemoteFiles,
                peerName: context.peerName,
                transport: context.transport,
                progressRange: 0.48...0.62,
                phase: "正在接收对端文件",
                etaWorkBucket: .receiveFiles
            ) { completed, total, batchIndex, totalBatches in
                guard total > 0 else {
                    return "本次没有需要接收的文件。"
                }
                return "已接收 \(completed)/\(total) 个文件（第 \(batchIndex)/\(totalBatches) 批）。"
            }
            let remoteFilesByPath = Dictionary(uniqueKeysWithValues: remoteBundleMessage.files.map { ($0.path, $0) })

            updateSyncProgress(
                0.62,
                phase: "正在准备应用变更",
                detail: remoteOperations.isEmpty
                    ? "本次不需要让 \(context.peerName) 应用来自本机的变更。"
                    : "正在通知 \(context.peerName) 拉取并应用 \(remoteOperations.count) 项变更。"
            )

            let remoteApplyTask = Task {
                try await self.sendPlanAndAwaitResult(
                    requestID: context.requestID,
                    plan: plan,
                    attachments: [],
                    peerName: context.peerName,
                    transport: context.transport
                )
            }

            let localFailures = try await applyOperationsInBatches(
                requestID: context.requestID,
                localOperations,
                on: context.root,
                localRole: .initiator,
                remoteFilesByPath: remoteFilesByPath,
                progressRange: 0.68...0.82,
                phase: "正在更新本机文件",
                etaWorkBucket: .applyLocalChanges
            ) { completed, total, batchIndex, totalBatches in
                guard total > 0 else {
                    return "本机没有需要写入的变更，正在等待对端处理。"
                }
                return "已处理 \(completed)/\(total) 项本机变更（第 \(batchIndex)/\(totalBatches) 批）。"
            }

            if var localManifest = pendingLocalManifests[context.requestID] {
                applyOperationsToManifest(
                    &localManifest,
                    operations: localOperations,
                    excludingFailuresAt: Set(localFailures.map(\.path))
                )
                if !localFailures.isEmpty {
                    try await refreshManifestEntries(
                        &localManifest,
                        root: context.root,
                        relativePaths: Set(localFailures.map(\.path))
                    )
                }
                pendingLocalManifests[context.requestID] = localManifest
            }

            updateSyncProgress(
                0.82,
                phase: "等待对端完成",
                detail: remoteOperations.isEmpty
                    ? "\(context.peerName) 正在确认同步结果。"
                    : "\(context.peerName) 正在应用 \(remoteOperations.count) 项变更。"
            )
            let remoteApplyResult = try await remoteApplyTask.value
            markETAWorkComplete(
                .applyRemoteChanges,
                total: Double(remoteOperations.count),
                requestID: context.requestID
            )

            let failurePaths = Set(
                remoteBundleMessage.failures.map(\.path)
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
            setETAWork(.finalize, completed: 0.5, total: 1, requestID: context.requestID)
            try storage.saveBaseline(updatedBaseline, for: context.peerHello.deviceID, rootPath: context.root.path)
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
            markETAWorkComplete(.finalize, total: 1, requestID: context.requestID)
            completeSyncProgress(phase: "同步完成", detail: statusText)
            addLog(statusText)
            if let finalManifest = pendingLocalManifests[context.requestID] {
                try await persistLocalSyncState(
                    for: context.peerHello.deviceID,
                    root: context.root,
                    fullManifest: finalManifest
                )
            } else {
                try await persistLocalSyncState(
                    for: context.peerHello.deviceID,
                    root: context.root,
                    changedPaths: Set(commitChanges.map(\.path))
                )
            }
            pendingLocalManifests.removeValue(forKey: context.requestID)
            playCompletionSoundIfNeeded(for: context.trigger)
        } catch {
            if ownsLocalSession(requestID: context.requestID) {
                try? context.transport.sendPayload(
                    SyncErrorMessage(requestID: context.requestID, message: error.localizedDescription),
                    kind: .syncError,
                    to: context.peerName
                )
            }
            pendingLocalManifests.removeValue(forKey: context.requestID)
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

    @discardableResult
    private func promoteActiveSessionToManualIfNeeded() -> Bool {
        guard let activeSession, activeSession.trigger == .automatic else {
            return false
        }

        switch activeSession {
        case let .awaitingPermission(requestID, _, peerDeviceID):
            self.activeSession = .awaitingPermission(
                requestID: requestID,
                trigger: .manual,
                peerDeviceID: peerDeviceID
            )
        case let .initiating(requestID, _, peerDeviceID):
            self.activeSession = .initiating(
                requestID: requestID,
                trigger: .manual,
                peerDeviceID: peerDeviceID
            )
        case let .responding(requestID, _, peerDeviceID):
            self.activeSession = .responding(
                requestID: requestID,
                trigger: .manual,
                peerDeviceID: peerDeviceID
            )
        }

        statusText = "\(SyncTriggerLabel.manual.rawValue)中..."
        if let syncProgress {
            self.syncProgress = SyncProgressSnapshot(
                phase: syncProgress.phase,
                detail: syncProgress.detail.replacingOccurrences(
                    of: SyncTriggerLabel.automatic.rawValue,
                    with: SyncTriggerLabel.manual.rawValue
                ),
                fractionCompleted: syncProgress.fractionCompleted,
                estimatedCompletionDate: syncProgress.estimatedCompletionDate
            )
        }
        addLog("已将当前同步会话提升为\(SyncTriggerLabel.manual.rawValue)。")
        return true
    }

    private func fileServiceProgressRange(for requestID: UUID) -> ClosedRange<Double> {
        if ownsLocalSession(requestID: requestID) {
            return 0.64...0.80
        }
        return 0.46...0.60
    }

    private func hasActiveSyncSession(requestID: UUID) -> Bool {
        activeSession?.requestID == requestID
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
                        backupPath: backupPath
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
                try await persistLocalSyncState(
                    for: peerHello.deviceID,
                    root: root,
                    changedPaths: Set(baselineChanges.map(\.path))
                )
                statusText = "冲突处理部分完成，建议重新同步确认最新状态。"
                completeSyncProgress(phase: "冲突处理部分完成", detail: statusText)
                addLog(statusText)
                playCompletionSoundIfNeeded(for: .manual)
                return
            }

            let baseline = storage.loadBaseline(for: peerHello.deviceID, rootPath: root.path)
            var updatedBaseline = baseline
            updateBaseline(&updatedBaseline, with: baselineChanges)
            updateSyncProgress(
                0.92,
                phase: "正在提交冲突结果",
                detail: "正在更新两台电脑的同步基线。"
            )
            try storage.saveBaseline(updatedBaseline, for: peerHello.deviceID, rootPath: root.path)
            try transport.sendPayload(
                CommitBaselineMessage(requestID: requestID, changes: baselineChanges),
                kind: .commitBaseline,
                to: peerName
            )
            try await persistLocalSyncState(
                for: peerHello.deviceID,
                root: root,
                changedPaths: Set(baselineChanges.map(\.path))
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
        var map = Dictionary(
            uniqueKeysWithValues: requestedFiles(
                for: plan.operations.filter { $0.target == .initiator && $0.source == .responder }
            ).map { ($0.path, $0) }
        )

        for conflict in plan.conflicts {
            if let expected = conflict.responderState, !expected.isDirectory {
                map[conflict.path] = RequestedFile(path: conflict.path, expectedState: expected)
            }
        }

        return map.keys.sorted().compactMap { map[$0] }
    }

    private func requestedFiles(for operations: [SyncOperation]) -> [RequestedFile] {
        var map: [String: RequestedFile] = [:]

        for operation in operations {
            guard let expected = operation.resultingState, !expected.isDirectory else {
                continue
            }
            map[operation.path] = RequestedFile(path: operation.path, expectedState: expected)
        }

        return map.keys.sorted().compactMap { map[$0] }
    }

    private func chunkRequestedFiles(_ files: [RequestedFile]) -> [[RequestedFile]] {
        guard !files.isEmpty else {
            return []
        }

        var batches: [[RequestedFile]] = []
        var currentBatch: [RequestedFile] = []
        var currentBytes: Int64 = 0

        for file in files {
            let fileBytes = max(1, file.expectedState.size)
            let wouldExceedCount = currentBatch.count >= AppConstants.maxTransferBatchFiles
            let wouldExceedBytes = currentBytes + fileBytes > Int64(AppConstants.maxTransferBatchBytes)

            if !currentBatch.isEmpty && (wouldExceedCount || wouldExceedBytes) {
                batches.append(currentBatch)
                currentBatch = []
                currentBytes = 0
            }

            currentBatch.append(file)
            currentBytes += fileBytes
        }

        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }

        return batches
    }

    private func chunkOperations(_ operations: [SyncOperation]) -> [[SyncOperation]] {
        let orderedOperations = orderedOperationsForApplication(operations)
        guard !orderedOperations.isEmpty else {
            return []
        }

        var batches: [[SyncOperation]] = []
        var index = 0

        while index < orderedOperations.count {
            let upperBound = min(index + AppConstants.maxOperationBatchCount, orderedOperations.count)
            batches.append(Array(orderedOperations[index..<upperBound]))
            index = upperBound
        }

        return batches
    }

    private func orderedOperationsForApplication(_ operations: [SyncOperation]) -> [SyncOperation] {
        operations.sorted { lhs, rhs in
            if lhs.isDeletion != rhs.isDeletion {
                return lhs.isDeletion == false
            }

            let lhsDepth = lhs.path.split(separator: "/").count
            let rhsDepth = rhs.path.split(separator: "/").count

            if lhs.isDeletion {
                if lhsDepth != rhsDepth {
                    return lhsDepth > rhsDepth
                }
            } else {
                let lhsDirectory = lhs.resultingState?.isDirectory ?? false
                let rhsDirectory = rhs.resultingState?.isDirectory ?? false
                if lhsDirectory != rhsDirectory {
                    return lhsDirectory
                }
                if lhsDepth != rhsDepth {
                    return lhsDepth < rhsDepth
                }
            }

            return lhs.path < rhs.path
        }
    }

    private func progressFraction(in range: ClosedRange<Double>, completed: Int, total: Int) -> Double {
        guard total > 0 else {
            return range.upperBound
        }

        let normalized = min(max(Double(completed) / Double(total), 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * normalized
    }

    private func requestFilesInBatches(
        requestID: UUID,
        files: [RequestedFile],
        peerName: String,
        transport: PeerTransport,
        progressRange: ClosedRange<Double>,
        phase: String,
        etaWorkBucket: OverallETAWorkBucket? = nil,
        detailBuilder: (_ completed: Int, _ total: Int, _ batchIndex: Int, _ totalBatches: Int) -> String
    ) async throws -> FileBundleMessage {
        guard !files.isEmpty else {
            return FileBundleMessage(requestID: requestID, files: [], failures: [])
        }

        let batches = chunkRequestedFiles(files)
        var aggregatedFiles: [BundledFile] = []
        var aggregatedFailures: [ApplyFailure] = []
        var completedCount = 0

        for (index, batch) in batches.enumerated() {
            if let etaWorkBucket {
                setETAWork(
                    etaWorkBucket,
                    completed: Double(completedCount),
                    total: Double(files.count),
                    requestID: requestID
                )
            }
            updateSyncProgress(
                progressFraction(in: progressRange, completed: completedCount, total: files.count),
                phase: phase,
                detail: detailBuilder(completedCount, files.count, index + 1, batches.count)
            )

            let response = try await requestFilesBatch(
                requestID: requestID,
                files: batch,
                batchIndex: index + 1,
                totalBatches: batches.count,
                totalRequestedFiles: files.count,
                completedFileCount: completedCount,
                peerName: peerName,
                transport: transport
            )

            aggregatedFiles.append(contentsOf: response.files)
            aggregatedFailures.append(contentsOf: response.failures)
            completedCount += batch.count

            if let etaWorkBucket {
                setETAWork(
                    etaWorkBucket,
                    completed: Double(completedCount),
                    total: Double(files.count),
                    requestID: requestID
                )
            }
            updateSyncProgress(
                progressFraction(in: progressRange, completed: completedCount, total: files.count),
                phase: phase,
                detail: detailBuilder(completedCount, files.count, index + 1, batches.count)
            )
        }

        return FileBundleMessage(
            requestID: requestID,
            files: aggregatedFiles,
            failures: aggregatedFailures
        )
    }

    private func applyOperationsInBatches(
        requestID: UUID,
        _ operations: [SyncOperation],
        on root: URL,
        localRole: PlanRole,
        remoteFilesByPath: [String: BundledFile],
        progressRange: ClosedRange<Double>,
        phase: String,
        etaWorkBucket: OverallETAWorkBucket? = nil,
        detailBuilder: (_ completed: Int, _ total: Int, _ batchIndex: Int, _ totalBatches: Int) -> String
    ) async throws -> [ApplyFailure] {
        guard !operations.isEmpty else {
            updateSyncProgress(
                progressRange.upperBound,
                phase: phase,
                detail: detailBuilder(0, 0, 0, 0)
            )
            return []
        }

        let batches = chunkOperations(operations)
        var aggregatedFailures: [ApplyFailure] = []
        var completedCount = 0

        for (index, batch) in batches.enumerated() {
            if let etaWorkBucket {
                setETAWork(
                    etaWorkBucket,
                    completed: Double(completedCount),
                    total: Double(operations.count),
                    requestID: requestID
                )
            }
            updateSyncProgress(
                progressFraction(in: progressRange, completed: completedCount, total: operations.count),
                phase: phase,
                detail: detailBuilder(completedCount, operations.count, index + 1, batches.count)
            )

            let failures = try await applyOperations(
                batch,
                on: root,
                localRole: localRole,
                remoteFilesByPath: remoteFilesByPath
            )
            aggregatedFailures.append(contentsOf: failures)
            completedCount += batch.count

            if let etaWorkBucket {
                setETAWork(
                    etaWorkBucket,
                    completed: Double(completedCount),
                    total: Double(operations.count),
                    requestID: requestID
                )
            }
            updateSyncProgress(
                progressFraction(in: progressRange, completed: completedCount, total: operations.count),
                phase: phase,
                detail: detailBuilder(completedCount, operations.count, index + 1, batches.count)
            )
        }

        return aggregatedFailures
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

                if resultState.isDirectory {
                    do {
                        try scanner.writeDirectory(
                            root: root,
                            relativePath: operation.path,
                            modifiedAt: resultState.modifiedAt
                        )
                    } catch {
                        failures.append(ApplyFailure(path: operation.path, message: error.localizedDescription))
                    }
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
                if let backupPath, let responderState = conflict.responderState, responderState.isDirectory {
                    do {
                        try scanner.writeDirectory(root: root, relativePath: backupPath, modifiedAt: responderState.modifiedAt)
                    } catch {
                        failures.append(ApplyFailure(path: backupPath, message: error.localizedDescription))
                    }
                } else if let backupPath, let remoteBundle {
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
                        if localState.isDirectory {
                            try scanner.writeDirectory(root: root, relativePath: backupPath, modifiedAt: localState.modifiedAt)
                        } else {
                            let localFile = try scanner.bundleFile(root: root, relativePath: conflict.path, expectedState: localState)
                            try scanner.writeData(localFile.data, to: root, relativePath: backupPath, modifiedAt: localFile.fingerprint.modifiedAt)
                        }
                    } catch {
                        failures.append(ApplyFailure(path: backupPath, message: error.localizedDescription))
                    }
                }

                if let remoteState = conflict.responderState {
                    do {
                        if remoteState.isDirectory {
                            try scanner.writeDirectory(root: root, relativePath: conflict.path, modifiedAt: remoteState.modifiedAt)
                        } else {
                            guard let remoteBundle, equivalentState(remoteBundle.fingerprint, remoteState) else {
                                failures.append(ApplyFailure(path: conflict.path, message: "对端预览内容已经过期。"))
                                return failures
                            }
                            try scanner.writeData(
                                remoteBundle.data,
                                to: root,
                                relativePath: conflict.path,
                                modifiedAt: remoteBundle.fingerprint.modifiedAt
                            )
                        }
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

    private func expectedChunkCount(for fileSize: Int64) -> Int {
        guard fileSize > 0 else {
            return 0
        }
        let chunkSize = Int64(AppConstants.fileTransferChunkBytes)
        return Int(((fileSize - 1) / chunkSize) + 1)
    }

    private func incomingTransferDirectoryURL(for requestID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(AppConstants.appName, isDirectory: true)
            .appendingPathComponent("IncomingTransfers", isDirectory: true)
            .appendingPathComponent(requestID.uuidString, isDirectory: true)
    }

    private func incomingTransferFileURL(for path: String, in directoryURL: URL) -> URL {
        let pathURL = URL(fileURLWithPath: path)
        let ext = pathURL.pathExtension
        let filename = stableDigestString(path)
        if ext.isEmpty {
            return directoryURL.appendingPathComponent(filename, isDirectory: false)
        }
        return directoryURL
            .appendingPathComponent(filename, isDirectory: false)
            .appendingPathExtension(ext)
    }

    private func cleanupIncomingFileTransfer(_ requestID: UUID) {
        guard let transfer = incomingFileTransfers.removeValue(forKey: requestID) else {
            return
        }
        try? FileManager.default.removeItem(at: transfer.directoryURL)
    }

    private func failIncomingFileTransfer(_ requestID: UUID, message: String) {
        cleanupIncomingFileTransfer(requestID)
        let error = NSError(domain: AppConstants.appName, code: 402, userInfo: [NSLocalizedDescriptionKey: message])
        fileWaiters.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    private func handleFileTransferStart(_ message: FileTransferStartMessage) {
        cleanupIncomingFileTransfer(message.requestID)

        let directoryURL = incomingTransferDirectoryURL(for: message.requestID)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            failIncomingFileTransfer(message.requestID, message: "创建临时接收目录失败：\(error.localizedDescription)")
            return
        }

        var filesByPath: [String: IncomingTransferredFileState] = [:]
        for descriptor in message.files {
            let temporaryURL = incomingTransferFileURL(for: descriptor.path, in: directoryURL)
            if descriptor.fingerprint.size == 0 {
                FileManager.default.createFile(atPath: temporaryURL.path, contents: Data())
            }
            filesByPath[descriptor.path] = IncomingTransferredFileState(
                descriptor: descriptor,
                temporaryURL: temporaryURL
            )
        }

        incomingFileTransfers[message.requestID] = PendingIncomingFileTransfer(
            directoryURL: directoryURL,
            failures: message.failures,
            fileOrder: message.files.map(\.path),
            filesByPath: filesByPath
        )
    }

    private func handleFileTransferChunk(_ message: FileTransferChunkMessage) {
        guard var transfer = incomingFileTransfers[message.requestID] else {
            return
        }
        guard var file = transfer.filesByPath[message.path] else {
            failIncomingFileTransfer(message.requestID, message: "收到未知文件 \(message.path) 的分块数据。")
            return
        }

        guard message.chunkIndex == file.nextChunkIndex else {
            failIncomingFileTransfer(message.requestID, message: "文件 \(message.path) 的分块顺序异常。")
            return
        }

        if let expectedTotalChunks = file.expectedTotalChunks, expectedTotalChunks != message.totalChunks {
            failIncomingFileTransfer(message.requestID, message: "文件 \(message.path) 的分块数量发生变化。")
            return
        }

        do {
            if !FileManager.default.fileExists(atPath: file.temporaryURL.path) {
                FileManager.default.createFile(atPath: file.temporaryURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file.temporaryURL)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: message.data)
        } catch {
            failIncomingFileTransfer(message.requestID, message: "写入文件 \(message.path) 的分块失败：\(error.localizedDescription)")
            return
        }

        file.receivedBytes += Int64(message.data.count)
        file.nextChunkIndex += 1
        file.expectedTotalChunks = message.totalChunks
        transfer.filesByPath[message.path] = file
        incomingFileTransfers[message.requestID] = transfer
    }

    private func handleFileTransferComplete(_ message: FileTransferCompleteMessage) {
        guard let transfer = incomingFileTransfers[message.requestID] else {
            let fallback = FileBundleMessage(requestID: message.requestID, files: [], failures: [])
            fileWaiters.removeValue(forKey: message.requestID)?.resume(returning: fallback)
            return
        }

        defer {
            cleanupIncomingFileTransfer(message.requestID)
        }

        do {
            var files: [BundledFile] = []

            for path in transfer.fileOrder {
                guard let file = transfer.filesByPath[path] else {
                    throw NSError(
                        domain: AppConstants.appName,
                        code: 403,
                        userInfo: [NSLocalizedDescriptionKey: "缺少文件 \(path) 的接收状态。"]
                    )
                }

                let expectedState = file.descriptor.fingerprint
                let expectedChunks = expectedChunkCount(for: expectedState.size)
                if file.receivedBytes != expectedState.size {
                    throw NSError(
                        domain: AppConstants.appName,
                        code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "文件 \(path) 接收不完整，期望 \(expectedState.size) 字节，实际 \(file.receivedBytes) 字节。"]
                    )
                }
                if file.nextChunkIndex != expectedChunks || (file.expectedTotalChunks ?? expectedChunks) != expectedChunks {
                    throw NSError(
                        domain: AppConstants.appName,
                        code: 405,
                        userInfo: [NSLocalizedDescriptionKey: "文件 \(path) 的分块数量校验失败。"]
                    )
                }

                let data = expectedState.size == 0 ? Data() : try Data(contentsOf: file.temporaryURL)
                if expectedState.size > 0 {
                    let actualState = try scanner.fingerprintForRegularFile(at: file.temporaryURL)
                    guard equivalentState(actualState, expectedState) else {
                        throw NSError(
                            domain: AppConstants.appName,
                            code: 406,
                            userInfo: [NSLocalizedDescriptionKey: "文件 \(path) 在接收后校验失败。"]
                        )
                    }
                }

                files.append(BundledFile(path: path, fingerprint: expectedState, data: data))
            }

            let bundle = FileBundleMessage(
                requestID: message.requestID,
                files: files,
                failures: transfer.failures
            )
            fileWaiters.removeValue(forKey: message.requestID)?.resume(returning: bundle)
        } catch {
            let nsError = error as NSError
            fileWaiters.removeValue(forKey: message.requestID)?.resume(throwing: nsError)
        }
    }

    private func sendFileInChunks(
        descriptor: TransferredFileDescriptor,
        from root: URL,
        requestID: UUID,
        peerName: String,
        transport: PeerTransport
    ) throws {
        let fileURL = scanner.absoluteURL(root: root, relativePath: descriptor.path)
        let totalChunks = expectedChunkCount(for: descriptor.fingerprint.size)
        guard totalChunks > 0 else {
            return
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var chunkIndex = 0
        while true {
            guard let chunk = try handle.read(upToCount: AppConstants.fileTransferChunkBytes), !chunk.isEmpty else {
                break
            }

            try transport.sendPayload(
                FileTransferChunkMessage(
                    requestID: requestID,
                    path: descriptor.path,
                    chunkIndex: chunkIndex,
                    totalChunks: totalChunks,
                    data: chunk
                ),
                kind: .fileTransferChunk,
                to: peerName
            )
            chunkIndex += 1
        }
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
        localDelta: DirectoryDeltaManifest,
        peerName: String,
        transport: PeerTransport
    ) async throws -> SyncManifestMessage {
        do {
            return try await withTimeout("同步清单交换") {
                try await withCheckedThrowingContinuation { continuation in
                    self.manifestWaiters[requestID] = continuation
                    do {
                        try transport.sendPayload(
                            SyncOfferMessage(
                                requestID: requestID,
                                baselineDigest: baselineDigest,
                                delta: localDelta
                            ),
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

    private func requestFilesBatch(
        requestID: UUID,
        files: [RequestedFile],
        batchIndex: Int,
        totalBatches: Int,
        totalRequestedFiles: Int,
        completedFileCount: Int,
        peerName: String,
        transport: PeerTransport
    ) async throws -> FileBundleMessage {
        guard !files.isEmpty else {
            return FileBundleMessage(requestID: requestID, files: [], failures: [])
        }

        do {
            return try await withTimeout(
                "文件拉取",
                timeoutSeconds: timeoutSecondsForFileBatch(files)
            ) {
                try await withCheckedThrowingContinuation { continuation in
                    self.fileWaiters[requestID] = continuation
                    do {
                        try transport.sendPayload(
                            FileRequestMessage(
                                requestID: requestID,
                                files: files,
                                batchIndex: batchIndex,
                                totalBatches: totalBatches,
                                totalRequestedFiles: totalRequestedFiles,
                                completedFileCount: completedFileCount
                            ),
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
            return try await withTimeout(
                "远端应用同步计划",
                timeoutSeconds: timeoutSecondsForRemoteApply(plan)
            ) {
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
            return try await withTimeout("远端执行冲突决议", timeoutSeconds: 60) {
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
        if responderState.isDirectory {
            return nil
        }

        if let url = pending.remotePreviewURL, let data = try? Data(contentsOf: url) {
            return BundledFile(path: pending.conflict.path, fingerprint: responderState, data: data)
        }

        let bundleMessage = try await requestFilesBatch(
            requestID: UUID(),
            files: [RequestedFile(path: pending.conflict.path, expectedState: responderState)],
            batchIndex: 1,
            totalBatches: 1,
            totalRequestedFiles: 1,
            completedFileCount: 0,
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

    private func scanLocalState(
        root: URL,
        baseline: [String: FileFingerprint],
        peerDeviceID: String
    ) async throws -> LocalScanResult {
        let scanner = DirectoryScanner()
        changeMonitor.flushPendingEvents(for: root)
        let cachedFiles = storage.loadLocalFingerprintCache(for: peerDeviceID, rootPath: root.path)
        let hasCachedManifest = storage.hasLocalFingerprintCache(for: peerDeviceID, rootPath: root.path)
        let peerCursor = storage.loadPeerSyncCursor(for: peerDeviceID, rootPath: root.path)
        let journal = changeMonitor.journalSnapshot(for: root)
        let canUseIncremental = {
            guard let peerCursor, hasCachedManifest else {
                return false
            }
            return !journal.requiresFullRescan && journal.lastObservedEventID >= peerCursor.lastSyncedLocalEventID
        }()
        let dirtyPaths = canUseIncremental && peerCursor != nil
            ? journal.changedPaths(since: peerCursor!.lastSyncedLocalEventID)
            : []

        return try await Task.detached(priority: .userInitiated) {
            if canUseIncremental {
                return try scanner.scanIncremental(
                    root: root,
                    cachedFiles: cachedFiles,
                    baseline: baseline,
                    dirtyPaths: dirtyPaths
                )
            }
            return try scanner.scan(root: root, cachedFiles: cachedFiles, baseline: baseline)
        }.value
    }

    private func currentState(for relativePath: String, root: URL) async throws -> FileFingerprint? {
        let scanner = DirectoryScanner()
        return try await Task.detached(priority: .userInitiated) {
            try scanner.currentState(root: root, relativePath: relativePath)
        }.value
    }

    private func refreshManifestEntries(
        _ manifest: inout [String: FileFingerprint],
        root: URL,
        relativePaths: Set<String>
    ) async throws {
        let scanner = DirectoryScanner()
        let refreshed = try await Task.detached(priority: .utility) {
            var updatedStates: [String: FileFingerprint?] = [:]
            for path in relativePaths.sorted() {
                updatedStates[path] = try scanner.currentState(root: root, relativePath: path)
            }
            return updatedStates
        }.value

        for (path, state) in refreshed {
            if let state {
                manifest[path] = state
            } else {
                manifest.removeValue(forKey: path)
            }
        }
    }

    private func estimatedScanWorkUnitCount(
        root: URL,
        peerDeviceID: String,
        baseline: [String: FileFingerprint]
    ) -> Int {
        let cachedFiles = storage.loadLocalFingerprintCache(for: peerDeviceID, rootPath: root.path)
        if storage.hasLocalFingerprintCache(for: peerDeviceID, rootPath: root.path),
           let peerCursor = storage.loadPeerSyncCursor(for: peerDeviceID, rootPath: root.path) {
            let journal = changeMonitor.journalSnapshot(for: root)
            if !journal.requiresFullRescan && journal.lastObservedEventID >= peerCursor.lastSyncedLocalEventID {
                return max(1, journal.changedPaths(since: peerCursor.lastSyncedLocalEventID).count)
            }
        }
        return max(1, cachedFiles.count, baseline.count)
    }

    private func persistLocalSyncState(
        for peerDeviceID: String,
        root: URL,
        fullManifest: [String: FileFingerprint]? = nil,
        changedPaths: Set<String> = []
    ) async throws {
        let manifest: [String: FileFingerprint]
        if let fullManifest {
            manifest = fullManifest
        } else {
            var refreshedManifest = storage.loadLocalFingerprintCache(for: peerDeviceID, rootPath: root.path)
            if !changedPaths.isEmpty {
                try await refreshManifestEntries(
                    &refreshedManifest,
                    root: root,
                    relativePaths: changedPaths
                )
            }
            manifest = refreshedManifest
        }

        try storage.saveLocalFingerprintCache(manifest, for: peerDeviceID, rootPath: root.path)
        let eventID = changeMonitor.markSynchronizedAndCaptureEventID(for: root)
        try storage.savePeerSyncCursor(
            PeerSyncCursorState(lastSyncedLocalEventID: eventID, updatedAt: Date()),
            for: peerDeviceID,
            rootPath: root.path
        )
    }

    private func timeoutSecondsForFileBatch(_ files: [RequestedFile]) -> TimeInterval {
        let totalBytes = files.reduce(Int64(0)) { partial, file in
            partial + max(Int64(1), file.expectedState.size)
        }
        let baseSeconds = 20.0
        let byteAllowance = Double(totalBytes) / Double(256 * 1_024)
        let fileCountAllowance = Double(files.count) * 0.1
        let timeout = baseSeconds + byteAllowance + fileCountAllowance
        return min(180, max(30, timeout))
    }

    private func timeoutSecondsForRemoteApply(_ plan: SyncPlan) -> TimeInterval {
        let responderOperations = plan.operations.filter { $0.target == .responder }
        let filesToServe = requestedFiles(
            for: responderOperations.filter { $0.source == .initiator }
        )
        let fileBatchCount = chunkRequestedFiles(filesToServe).count
        let operationBatchCount = chunkOperations(responderOperations).count
        let totalBytes = filesToServe.reduce(Int64(0)) { partial, file in
            partial + max(Int64(1), file.expectedState.size)
        }

        let baseSeconds = 45.0
        let batchAllowance = Double(fileBatchCount) * 10
        let operationAllowance = Double(operationBatchCount) * 4
        let byteAllowance = Double(totalBytes) / Double(512 * 1_024)
        let pathAllowance = Double(responderOperations.count) * 0.02
        let timeout = baseSeconds + batchAllowance + operationAllowance + byteAllowance + pathAllowance
        return min(1_800, max(45, timeout))
    }

    private func estimatedCurrentFileCount(
        baseline: [String: FileFingerprint],
        delta: DirectoryDeltaManifest,
        fallback: Int
    ) -> Int {
        var estimatedCount = baseline.count

        for path in delta.deletedPaths where baseline[path] != nil {
            estimatedCount -= 1
        }

        for path in delta.changedFiles.keys where baseline[path] == nil {
            estimatedCount += 1
        }

        return max(1, estimatedCount, fallback)
    }

    private func startOverallETAEstimate(requestID: UUID) {
        let now = Date()
        progressStartedAt = now
        var estimate = OverallSyncETAEstimate(requestID: requestID, startedAt: now)
        estimate.work[.handshake] = OverallETAWorkState(completed: 0, total: 1)
        estimate.work[.planning] = OverallETAWorkState(completed: 0, total: 1)
        estimate.work[.finalize] = OverallETAWorkState(completed: 0, total: 1)
        overallETAEstimate = estimate
    }

    private func ensureOverallETAEstimate(requestID: UUID) {
        guard overallETAEstimate?.requestID != requestID else {
            return
        }
        startOverallETAEstimate(requestID: requestID)
    }

    private func setETAWork(
        _ bucket: OverallETAWorkBucket,
        completed: Double,
        total: Double,
        requestID: UUID
    ) {
        ensureOverallETAEstimate(requestID: requestID)
        guard var estimate = overallETAEstimate, estimate.requestID == requestID else {
            return
        }

        let clampedTotal = max(total, 0)
        let clampedCompleted = min(max(completed, 0), clampedTotal)
        estimate.work[bucket] = OverallETAWorkState(completed: clampedCompleted, total: clampedTotal)
        overallETAEstimate = estimate
    }

    private func markETAWorkComplete(
        _ bucket: OverallETAWorkBucket,
        total: Double? = nil,
        requestID: UUID
    ) {
        ensureOverallETAEstimate(requestID: requestID)
        guard var estimate = overallETAEstimate, estimate.requestID == requestID else {
            return
        }

        let currentTotal = max(total ?? estimate.work[bucket]?.total ?? 0, 0)
        estimate.work[bucket] = OverallETAWorkState(completed: currentTotal, total: currentTotal)
        overallETAEstimate = estimate
    }

    private func overallETAFraction(for requestID: UUID?) -> Double? {
        guard
            let requestID,
            let overallETAEstimate,
            overallETAEstimate.requestID == requestID
        else {
            return nil
        }

        return overallETAEstimate.overallFraction
    }

    private func applyOperationsToManifest(
        _ manifest: inout [String: FileFingerprint],
        operations: [SyncOperation],
        excludingFailuresAt failurePaths: Set<String>
    ) {
        for operation in operations where !failurePaths.contains(operation.path) {
            if let resultingState = operation.resultingState {
                manifest[operation.path] = resultingState
            } else {
                manifest.removeValue(forKey: operation.path)
            }
        }
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

    private func estimatedCompletionDate(for requestID: UUID?, now: Date) -> Date? {
        guard let progressStartedAt else {
            return nil
        }
        guard let clamped = overallETAFraction(for: requestID), clamped < 0.995 else {
            return nil
        }

        let elapsed = now.timeIntervalSince(progressStartedAt)
        guard elapsed >= 1 else {
            return nil
        }

        let remaining = elapsed * (1 - clamped) / clamped
        guard remaining.isFinite, remaining > 0 else {
            return nil
        }

        return now.addingTimeInterval(remaining)
    }

    private func updateSyncProgress(_ fraction: Double, phase: String, detail: String) {
        progressResetTask?.cancel()
        progressResetTask = nil
        let now = Date()
        if progressStartedAt == nil {
            progressStartedAt = now
        }
        syncProgress = SyncProgressSnapshot(
            phase: phase,
            detail: detail,
            fractionCompleted: fraction,
            estimatedCompletionDate: estimatedCompletionDate(for: activeSession?.requestID, now: now)
        )
    }

    private func completeSyncProgress(phase: String, detail: String) {
        progressResetTask?.cancel()
        syncProgress = SyncProgressSnapshot(
            phase: phase,
            detail: detail,
            fractionCompleted: 1,
            estimatedCompletionDate: nil
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
        progressStartedAt = nil
        overallETAEstimate = nil
        syncProgress = nil
    }

    private func resetSessionStateIfMatches(_ requestID: UUID) {
        if activeSession?.requestID == requestID {
            clearSyncProgress()
        }
        if overallETAEstimate?.requestID == requestID {
            overallETAEstimate = nil
        }
        pendingLocalManifests.removeValue(forKey: requestID)
        cleanupIncomingFileTransfer(requestID)
        releaseActiveSessionIfMatches(requestID)
    }

    private func withTimeout<T>(
        _ stage: String,
        timeoutSeconds: TimeInterval = 20,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let normalizedTimeout = max(1, timeoutSeconds)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(normalizedTimeout * 1_000_000_000))
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
        progressStartedAt = nil
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
        pendingLocalManifests.removeAll()
        let transferIDs = Array(incomingFileTransfers.keys)
        for requestID in transferIDs {
            cleanupIncomingFileTransfer(requestID)
        }
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

            case .fileTransferStart:
                let message = try SyncMessageCodec.decodePayload(FileTransferStartMessage.self, from: envelope)
                handleFileTransferStart(message)

            case .fileTransferChunk:
                let message = try SyncMessageCodec.decodePayload(FileTransferChunkMessage.self, from: envelope)
                handleFileTransferChunk(message)

            case .fileTransferComplete:
                let message = try SyncMessageCodec.decodePayload(FileTransferCompleteMessage.self, from: envelope)
                handleFileTransferComplete(message)

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
                Task {
                    await handleCommitBaseline(message)
                }

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
            ensureOverallETAEstimate(requestID: message.requestID)
            markETAWorkComplete(.handshake, total: 1, requestID: message.requestID)
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
            ensureOverallETAEstimate(requestID: message.requestID)
            updateSyncProgress(
                0.18,
                phase: "正在扫描本机目录",
                detail: "正在为 \(peerName) 准备本地目录清单。"
            )
            let localBaseline = storage.loadBaseline(for: remoteHello.deviceID, rootPath: root.path)
            let localDigest = SyncStateDigest.digest(for: localBaseline)
            guard localDigest == message.baselineDigest else {
                throw SyncControllerError.baselineMismatch
            }

            let estimatedLocalScanUnits = estimatedScanWorkUnitCount(
                root: root,
                peerDeviceID: remoteHello.deviceID,
                baseline: localBaseline
            )
            setETAWork(
                .localScan,
                completed: 0,
                total: Double(estimatedLocalScanUnits),
                requestID: message.requestID
            )
            markETAWorkComplete(
                .remoteScan,
                total: Double(
                    estimatedCurrentFileCount(
                        baseline: localBaseline,
                        delta: message.delta,
                        fallback: estimatedLocalScanUnits
                    )
                ),
                requestID: message.requestID
            )

            let localScanResult = try await scanLocalState(
                root: root,
                baseline: localBaseline,
                peerDeviceID: remoteHello.deviceID
            )
            markETAWorkComplete(
                .localScan,
                total: Double(max(estimatedLocalScanUnits, localScanResult.filesystemWorkUnits, 1)),
                requestID: message.requestID
            )
            pendingLocalManifests[message.requestID] = localScanResult.manifest.files
            try transport.sendPayload(
                SyncManifestMessage(
                    requestID: message.requestID,
                    baselineDigest: localDigest,
                    delta: localScanResult.delta
                ),
                kind: .syncManifest,
                to: peerName
            )
            updateSyncProgress(
                0.32,
                phase: "目录清单已发送",
                detail: localScanResult.delta.changedPathCount == 0
                    ? "本机自上次同步以来没有文件变更，等待 \(peerName) 生成同步计划。"
                    : "已将 \(localScanResult.delta.changedPathCount) 个变更路径发给 \(peerName)，等待对端生成同步计划。"
            )
            statusText = "已向 \(peerName) 发送本地目录清单。"
            addLog(statusText)
        } catch {
            try? transport.sendPayload(
                SyncErrorMessage(requestID: message.requestID, message: error.localizedDescription),
                kind: .syncError,
                to: peerName
            )
            pendingLocalManifests.removeValue(forKey: message.requestID)
            resetSessionStateIfMatches(message.requestID)
        }
    }

    private func handleFileRequest(_ message: FileRequestMessage, from peerName: String) async {
        guard let transport, let root = watchedFolderURL else {
            return
        }
        if let versionGateMessage {
            try? transport.sendPayload(
                SyncErrorMessage(
                    requestID: message.requestID,
                    message: versionGateMessage
                ),
                kind: .syncError,
                to: peerName
            )
            return
        }

        let progressRange = fileServiceProgressRange(for: message.requestID)
        let batchStartCount = min(message.completedFileCount, message.totalRequestedFiles)
        setETAWork(
            .sendFiles,
            completed: Double(batchStartCount),
            total: Double(message.totalRequestedFiles),
            requestID: message.requestID
        )
        updateSyncProgress(
            progressFraction(in: progressRange, completed: batchStartCount, total: message.totalRequestedFiles),
            phase: "正在准备同步文件",
            detail: message.totalRequestedFiles > 0
                ? "已整理 \(batchStartCount)/\(message.totalRequestedFiles) 个文件，正在处理第 \(message.batchIndex)/\(message.totalBatches) 批并发送给 \(peerName)。"
                : "正在整理文件发送给 \(peerName)。"
        )
        var filesToSend: [TransferredFileDescriptor] = []
        var failures: [ApplyFailure] = []

        for request in message.files {
            do {
                let current = try scanner.currentState(root: root, relativePath: request.path)
                guard equivalentState(current, request.expectedState) else {
                    failures.append(ApplyFailure(path: request.path, message: "文件在发送前已变化。"))
                    continue
                }
                filesToSend.append(
                    TransferredFileDescriptor(path: request.path, fingerprint: request.expectedState)
                )
            } catch {
                failures.append(ApplyFailure(path: request.path, message: error.localizedDescription))
            }
        }

        do {
            try transport.sendPayload(
                FileTransferStartMessage(
                    requestID: message.requestID,
                    files: filesToSend,
                    failures: failures
                ),
                kind: .fileTransferStart,
                to: peerName
            )

            for descriptor in filesToSend {
                try sendFileInChunks(
                    descriptor: descriptor,
                    from: root,
                    requestID: message.requestID,
                    peerName: peerName,
                    transport: transport
                )
            }

            try transport.sendPayload(
                FileTransferCompleteMessage(requestID: message.requestID),
                kind: .fileTransferComplete,
                to: peerName
            )
        } catch {
            try? transport.sendPayload(
                SyncErrorMessage(requestID: message.requestID, message: error.localizedDescription),
                kind: .syncError,
                to: peerName
            )
            return
        }
        let batchCompletedCount = min(
            message.completedFileCount + message.files.count,
            message.totalRequestedFiles
        )
        setETAWork(
            .sendFiles,
            completed: Double(batchCompletedCount),
            total: Double(message.totalRequestedFiles),
            requestID: message.requestID
        )
        updateSyncProgress(
            progressFraction(in: progressRange, completed: batchCompletedCount, total: message.totalRequestedFiles),
            phase: "文件已发送",
            detail: message.totalRequestedFiles > 0
                ? "已发送 \(batchCompletedCount)/\(message.totalRequestedFiles) 个文件给 \(peerName)。"
                : "已向 \(peerName) 发送文件。"
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
        let initiatorOperations = message.plan.operations.filter { $0.target == .initiator }
        var filesByPath = Dictionary(uniqueKeysWithValues: message.attachments.map { ($0.path, $0) })
        do {
            let filesToRequest = requestedFiles(
                for: responderOperations.filter { $0.source == .initiator }
            ).filter { filesByPath[$0.path] == nil }

            setETAWork(
                .receiveFiles,
                completed: 0,
                total: Double(filesToRequest.count),
                requestID: message.requestID
            )
            setETAWork(
                .applyLocalChanges,
                completed: 0,
                total: Double(responderOperations.count),
                requestID: message.requestID
            )
            setETAWork(
                .applyRemoteChanges,
                completed: 0,
                total: Double(initiatorOperations.count),
                requestID: message.requestID
            )
            markETAWorkComplete(.planning, total: 1, requestID: message.requestID)

            var transferFailures: [ApplyFailure] = []
            if !filesToRequest.isEmpty {
                let bundle = try await requestFilesInBatches(
                    requestID: message.requestID,
                    files: filesToRequest,
                    peerName: peerName,
                    transport: transport,
                    progressRange: 0.52...0.72,
                    phase: "正在接收待应用文件",
                    etaWorkBucket: .receiveFiles
                ) { completed, total, batchIndex, totalBatches in
                    "已接收 \(completed)/\(total) 个待应用文件（第 \(batchIndex)/\(totalBatches) 批）。"
                }
                transferFailures = bundle.failures
                for file in bundle.files {
                    filesByPath[file.path] = file
                }
            } else {
                updateSyncProgress(
                    0.72,
                    phase: "待应用文件已就绪",
                    detail: responderOperations.isEmpty
                        ? "本机没有需要写入的变更，正在确认结果。"
                        : "本轮变更不需要额外接收文件，准备开始写入。"
                )
            }

            let applyFailures = try await applyOperationsInBatches(
                requestID: message.requestID,
                responderOperations,
                on: root,
                localRole: .responder,
                remoteFilesByPath: filesByPath,
                progressRange: 0.72...0.88,
                phase: "正在应用对端变更",
                etaWorkBucket: .applyLocalChanges
            ) { completed, total, batchIndex, totalBatches in
                guard total > 0 else {
                    return "本机没有需要写入的变更，正在确认结果。"
                }
                return "已处理 \(completed)/\(total) 项对端变更（第 \(batchIndex)/\(totalBatches) 批）。"
            }
            let failures = transferFailures + applyFailures

            if var localManifest = pendingLocalManifests[message.requestID] {
                applyOperationsToManifest(
                    &localManifest,
                    operations: responderOperations,
                    excludingFailuresAt: Set(failures.map(\.path))
                )
                if !failures.isEmpty {
                    try await refreshManifestEntries(
                        &localManifest,
                        root: root,
                        relativePaths: Set(failures.map(\.path))
                    )
                }
                pendingLocalManifests[message.requestID] = localManifest
            }

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
        var transferFailures: [ApplyFailure] = []
        var initiatorFilesByPath: [String: BundledFile] = [:]

        if let initiatorState = message.conflict.initiatorState,
           !initiatorState.isDirectory,
           message.winningSide == .initiator || message.backupPath != nil {
            updateSyncProgress(
                0.32,
                phase: "正在接收冲突文件",
                detail: "正在从 \(peerName) 拉取冲突处理所需的文件内容。"
            )

            do {
                let bundle = try await requestFilesInBatches(
                    requestID: message.requestID,
                    files: [RequestedFile(path: message.conflict.path, expectedState: initiatorState)],
                    peerName: peerName,
                    transport: transport,
                    progressRange: 0.32...0.54,
                    phase: "正在接收冲突文件"
                ) { completed, total, _, _ in
                    "已接收 \(completed)/\(total) 个冲突文件。"
                }
                transferFailures = bundle.failures
                initiatorFilesByPath = Dictionary(uniqueKeysWithValues: bundle.files.map { ($0.path, $0) })
            } catch {
                transferFailures = [ApplyFailure(path: message.conflict.path, message: error.localizedDescription)]
            }
        }

        let applyFailures = await Task.detached(priority: .userInitiated) {
            var failures: [ApplyFailure] = []

            do {
                let current = try scanner.currentState(root: root, relativePath: message.conflict.path)
                guard equivalentState(current, message.conflict.responderState) else {
                    return [ApplyFailure(path: message.conflict.path, message: "对端冲突处理前，本机文件已变化。")]
                }

                if message.winningSide == .initiator {
                    if let backupPath = message.backupPath, let responderState = message.conflict.responderState {
                        do {
                            if responderState.isDirectory {
                                try scanner.writeDirectory(root: root, relativePath: backupPath, modifiedAt: responderState.modifiedAt)
                            } else {
                                let localFile = try scanner.bundleFile(root: root, relativePath: message.conflict.path, expectedState: responderState)
                                try scanner.writeData(localFile.data, to: root, relativePath: backupPath, modifiedAt: localFile.fingerprint.modifiedAt)
                            }
                        } catch {
                            failures.append(ApplyFailure(path: backupPath, message: error.localizedDescription))
                        }
                    }

                    if let winnerState = message.conflict.initiatorState, winnerState.isDirectory {
                        do {
                            try scanner.writeDirectory(root: root, relativePath: message.conflict.path, modifiedAt: winnerState.modifiedAt)
                        } catch {
                            failures.append(ApplyFailure(path: message.conflict.path, message: error.localizedDescription))
                        }
                    } else if let winnerState = message.conflict.initiatorState {
                        do {
                            guard let winnerFile = initiatorFilesByPath[message.conflict.path],
                                  equivalentState(winnerFile.fingerprint, winnerState) else {
                                failures.append(ApplyFailure(path: message.conflict.path, message: "未收到发起端的最新文件内容。"))
                                return failures
                            }
                            try scanner.writeData(
                                winnerFile.data,
                                to: root,
                                relativePath: message.conflict.path,
                                modifiedAt: winnerFile.fingerprint.modifiedAt
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
                    if let backupPath = message.backupPath, let initiatorState = message.conflict.initiatorState, initiatorState.isDirectory {
                        do {
                            try scanner.writeDirectory(root: root, relativePath: backupPath, modifiedAt: initiatorState.modifiedAt)
                        } catch {
                            failures.append(ApplyFailure(path: backupPath, message: error.localizedDescription))
                        }
                    } else if let backupPath = message.backupPath, let initiatorState = message.conflict.initiatorState {
                        do {
                            guard let loserFile = initiatorFilesByPath[message.conflict.path],
                                  equivalentState(loserFile.fingerprint, initiatorState) else {
                                failures.append(ApplyFailure(path: backupPath, message: "未收到需要备份的对端文件。"))
                                return failures
                            }
                            try scanner.writeData(
                                loserFile.data,
                                to: root,
                                relativePath: backupPath,
                                modifiedAt: loserFile.fingerprint.modifiedAt
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
        let failures = transferFailures + applyFailures

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

    private func handleCommitBaseline(_ message: CommitBaselineMessage) async {
        guard let remoteHello else {
            return
        }
        let rootPath = watchedFolderURL?.path ?? config.watchedFolderPath
        let root = watchedFolderURL
        let shouldCompleteResponderProgress = isResponderSession(requestID: message.requestID)
        defer {
            releaseActiveSessionIfMatches(message.requestID)
        }
        do {
            var baseline = storage.loadBaseline(for: remoteHello.deviceID, rootPath: rootPath)
            updateBaseline(&baseline, with: message.changes)
            try storage.saveBaseline(baseline, for: remoteHello.deviceID, rootPath: rootPath)
            addLog("已提交 \(message.changes.count) 条同步基线更新。")
            if let root, let manifest = pendingLocalManifests[message.requestID] {
                try await persistLocalSyncState(
                    for: remoteHello.deviceID,
                    root: root,
                    fullManifest: manifest
                )
            } else if let root {
                try await persistLocalSyncState(
                    for: remoteHello.deviceID,
                    root: root,
                    changedPaths: Set(message.changes.map(\.path))
                )
            }
            pendingLocalManifests.removeValue(forKey: message.requestID)
            if overallETAEstimate?.requestID == message.requestID {
                markETAWorkComplete(.applyRemoteChanges, requestID: message.requestID)
                markETAWorkComplete(.finalize, total: 1, requestID: message.requestID)
            }
            if shouldCompleteResponderProgress {
                completeSyncProgress(
                    phase: "同步完成",
                    detail: "两台电脑都已确认本轮同步结果。"
                )
            }
        } catch {
            pendingLocalManifests.removeValue(forKey: message.requestID)
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
                cleanupIncomingFileTransfer(requestID)
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
            cleanupIncomingFileTransfer(requestID)
            clearSyncProgress()
            releaseActiveSessionIfMatches(requestID)
        }
        clearSyncProgress()
        statusText = message.message
        addLog(message.message)
    }
}
