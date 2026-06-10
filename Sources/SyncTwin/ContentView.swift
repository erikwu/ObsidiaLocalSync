import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: SyncTwinController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let progress = controller.syncProgress {
                    progressPanel(progress)
                }
                settingsCard
                peersCard
                conflictsCard
                activityCard
            }
            .padding(24)
        }
        .frame(minWidth: 940, minHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SyncTwin")
                    .font(.system(size: 30, weight: .semibold))
                Text("局域网内双机目录同步，默认不覆盖任何一边的新内容。")
                    .foregroundStyle(.secondary)
                Text("本机版本 \(AppConstants.appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                StatusBadge(text: controller.statusText, isBusy: controller.isSyncInProgress)
                if let message = controller.versionGateMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 280, alignment: .trailing)
                }
            }
        }
    }

    private var settingsCard: some View {
        Card(title: "同步设置") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("设备名称")
                            .font(.headline)
                        TextField("例如：Erwu-MacBook", text: $controller.config.deviceName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("自动同步间隔（分钟）")
                            .font(.headline)
                        Stepper(
                            value: Binding(
                                get: { max(1, controller.config.syncIntervalSeconds / 60) },
                                set: { controller.config.syncIntervalSeconds = max(60, $0 * 60) }
                            ),
                            in: 1...720
                        ) {
                            Text("\(max(1, controller.config.syncIntervalSeconds / 60)) 分钟")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("同步目录")
                        .font(.headline)
                    HStack(spacing: 12) {
                        Text(controller.watchedFolderDisplayName)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button("选择目录") {
                            controller.pickFolder()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Toggle("按固定间隔自动同步", isOn: $controller.config.autoSyncEnabled)
                Toggle("自动同步完成时播放提示音", isOn: $controller.config.autoSyncCompletionSoundEnabled)
                    .disabled(!controller.config.autoSyncEnabled)

                HStack(spacing: 12) {
                    Button("保存设置") {
                        controller.saveSettings()
                    }
                    .buttonStyle(.bordered)

                    Button("立即同步") {
                        controller.startManualSync()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canSyncNow)
                }
            }
        }
    }

    private func progressPanel(_ progress: SyncProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.phase)
                    .font(.headline)
                Spacer()
                Text(progress.percentText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress.clampedFraction)
                .progressViewStyle(.linear)

            if !progress.detail.isEmpty {
                Text(progress.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var peersCard: some View {
        Card(title: "对端连接") {
            VStack(alignment: .leading, spacing: 12) {
                if let connectedPeerName = controller.connectedPeerName {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("已连接：\(connectedPeerName)")
                                .font(.headline)
                            if let remoteHello = controller.remoteHello {
                                Text("对端版本 \(remoteHello.appVersion) | 设备名 \(remoteHello.deviceName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("断开") {
                            controller.disconnect()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if controller.discoveredPeers.isEmpty {
                    Text("当前还没有发现其他已安装 SyncTwin 的 Mac，请确认两端都在同一局域网或蓝牙/点对点环境中。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.discoveredPeers) { peer in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(peer.displayName)
                                Text("通过 MultipeerConnectivity 做加密局域网传输")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(controller.connectedPeerName == peer.displayName ? "已连接" : "连接") {
                                controller.connect(to: peer)
                            }
                            .buttonStyle(.bordered)
                            .disabled(controller.connectedPeerName == peer.displayName)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var conflictsCard: some View {
        Card(title: "待处理冲突") {
            if controller.pendingConflicts.isEmpty {
                Text("暂时没有冲突。出现双方都改过同一路径的情况时，这里会要求人工判断，同时保留未选中的版本为冲突副本。")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(controller.pendingConflicts) { pending in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(pending.conflict.path)
                                .font(.headline)

                            Text(conflictDescription(for: pending))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 12) {
                                conflictSummary(title: "本机", state: pending.conflict.initiatorState)
                                conflictSummary(title: "对方", state: pending.conflict.responderState)
                            }

                            HStack(spacing: 12) {
                                Button("打开本机版") {
                                    controller.openLocalVersion(for: pending)
                                }
                                .buttonStyle(.bordered)

                                Button("打开对方快照") {
                                    controller.openRemotePreview(for: pending)
                                }
                                .buttonStyle(.bordered)
                                .disabled(pending.remotePreviewURL == nil)

                                Spacer()

                                Button("采用本机版本") {
                                    controller.resolve(pending, choice: .useLocal)
                                }
                                .buttonStyle(.bordered)

                                Button("采用对方版本") {
                                    controller.resolve(pending, choice: .useRemote)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(14)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var activityCard: some View {
        Card(title: "最近活动") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(controller.activityItems.prefix(10)) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Text(item.timestamp, style: .time)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        Text(item.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func conflictDescription(for pending: PendingConflict) -> String {
        switch pending.conflict.reason {
        case .bothModified:
            return "两台电脑都修改了这个文件，系统无法自动判断哪一版应当作为主版本。"
        case .modifyVsDelete:
            return "一边删除了这个路径，另一边仍然保留了更新内容，需要人工判断。"
        case .bothCreatedDifferently:
            return "两边都新增了同名文件，但内容不同。"
        }
    }

    private func conflictSummary(title: String, state: FileFingerprint?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(state?.shortSummary ?? "已删除")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
            content
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusBadge: View {
    let text: String
    let isBusy: Bool

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isBusy ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
            .clipShape(Capsule())
    }
}
