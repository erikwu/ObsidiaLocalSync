# SyncTwin

- English version: [README.en.md](./README.en.md)
- 文档维护约定：`README.md`、`README.en.md`、`Docs/SyncTwin_Product_Design.md`、`Docs/SyncTwin_Product_Design.en.md` 后续保持中英文同步更新。

`SyncTwin` 是一个 macOS 本地双机目录同步工具，面向两台都安装了同一版本应用的 MacBook。它使用苹果系统自带的 `MultipeerConnectivity` 做设备发现和加密传输，优先通过局域网、点对点 Wi-Fi 和蓝牙建立连接，不依赖互联网公网。

## 已实现的核心规则

- 同步前先做版本握手：两端 `appVersion` 或协议版本不一致时，直接拒绝同步。
- 开始真正扫描和传输之前，会先做一次同步会话握手：
  - 正在进行中的手工同步会阻止定时同步启动。
  - 两边如果几乎同时触发同步，只会有一边拿到本次同步会话，另一边自动让路并转为响应者。
- 自动同步只在一侧发起：用稳定的设备 ID 选主，避免定时器同时触发导致双发起。
- 切换或重新选择同步目录时，会清除该目录对应的历史基线、缓存和同步游标，避免旧同步历史误用于当前目录。
- 采用“共同基线 + 内容哈希”判断变化：
  - 只有一边改过：自动同步到另一边。
  - 两边都改了但内容相同：自动更新基线，不打扰人工。
  - 两边都改了且内容不同：进入冲突列表，等待人工判断。
  - 一边删除、一边修改：进入冲突列表，等待人工判断。
- 冲突决议不会直接丢弃未选中的内容：
  - 选择“采用本机版本”或“采用对方版本”时，未选中的版本会保留为同目录下的冲突副本文件。
- 支持手工同步和固定间隔自动同步。
- 同步范围是所选目录下的递归常规文件；会跳过符号链接，避免循环和越界。

## 工程结构

- `Sources/SyncTwin/SyncTwinApp.swift`
  - SwiftUI 应用入口。
- `Sources/SyncTwin/ContentView.swift`
  - 设置、发现对端、手工同步、冲突处理界面。
- `Sources/SyncTwin/SyncTwinController.swift`
  - 版本握手、同步流程、冲突决议、基线提交。
- `Sources/SyncTwin/PeerTransport.swift`
  - `MultipeerConnectivity` 发现、连接、消息发送。
- `Sources/SyncTwin/DirectoryScanner.swift`
  - 目录扫描、哈希计算、原子写入与删除。
- `Sources/SyncTwin/SyncPlanner.swift`
  - 基于基线的自动同步/冲突判定算法。

## 本地构建

如果本机已经安装并完成初始化 Xcode，可以直接：

```bash
swift build
```

如果想要把可执行文件打成双击可开的 `.app`，使用：

```bash
./Scripts/build-app.sh
```

打包结果会放到 `dist/SyncTwin.app`。

## 使用方式

1. 在两台 Mac 上安装并启动同版本的 `SyncTwin`。
2. 两边各自选择要同步的本地目录。
3. 在“对端连接”里连接到另一台电脑。
4. 完成版本校验后，可以手工点“立即同步”，或者开启自动同步。
5. 如果出现冲突，在“待处理冲突”里打开本机版/对方快照后做判断。

## 当前边界

- 当前实现主要覆盖常规文档、代码、配置等中小型文件目录。
- 单文件传输暂时采用内联数据消息，默认上限 32 MB；超过会阻止该文件同步并提示人工处理。
- 测试目录已预留同步规划测试样例；在本机工具链完整可用时可继续补充和运行。
