# SyncTwin

- Chinese version: [README.md](./README.md)
- Documentation maintenance policy: `README.md`, `README.en.md`, `Docs/SyncTwin_Product_Design.md`, and `Docs/SyncTwin_Product_Design.en.md` should be updated together in both Chinese and English going forward.

`SyncTwin` is a macOS local two-device directory sync tool for two MacBooks running the same app version. It uses Apple's built-in `MultipeerConnectivity` for peer discovery and encrypted transport, preferring LAN, peer-to-peer Wi-Fi, and Bluetooth, without relying on the public internet.

## Core Rules Already Implemented

- A version handshake runs before sync starts: if `appVersion` or the protocol version differs between the two sides, sync is rejected immediately.
- Before the real scan and transfer begin, the app performs a sync-session handshake:
  - A manual sync already in progress blocks scheduled sync from starting.
  - If both sides trigger sync at nearly the same time, only one side wins the session; the other side automatically yields and becomes the responder.
- Auto-sync is initiated by only one side: a stable device ID is used to pick the leader and avoid both timers initiating at once.
- When the sync directory is changed or reselected, the app clears that directory's historical baseline, cache, and sync cursor so that old sync history is not reused for the current directory.
- Changes are detected using a "shared baseline + content hash" model:
  - Changed on only one side: auto-sync to the other side.
  - Changed on both sides but with identical content: update the baseline automatically without bothering the user.
  - Changed on both sides with different content: move into the conflict list and wait for manual resolution.
  - Deleted on one side and modified on the other: move into the conflict list and wait for manual resolution.
- Conflict resolution never silently discards the unselected content:
  - When the user chooses "Use Local Version" or "Use Remote Version," the unselected version is preserved as a conflict-copy file in the same directory.
- Supports both manual sync and fixed-interval automatic sync.
- The sync scope is the selected directory's recursive regular files; symbolic links are skipped to avoid loops and out-of-bound traversal.

## Project Structure

- `Sources/SyncTwin/SyncTwinApp.swift`
  - SwiftUI app entry point.
- `Sources/SyncTwin/ContentView.swift`
  - UI for settings, peer discovery, manual sync, and conflict resolution.
- `Sources/SyncTwin/SyncTwinController.swift`
  - Version handshake, sync flow, conflict resolution, and baseline commit.
- `Sources/SyncTwin/PeerTransport.swift`
  - `MultipeerConnectivity` discovery, connection management, and message transport.
- `Sources/SyncTwin/DirectoryScanner.swift`
  - Directory scanning, hash calculation, atomic writes, and deletion.
- `Sources/SyncTwin/SyncPlanner.swift`
  - Baseline-driven auto-sync and conflict-detection algorithm.

## Local Build

If Xcode is already installed and initialized on this Mac, you can run:

```bash
swift build
```

If you want to package the executable as a double-clickable `.app`, run:

```bash
./Scripts/build-app.sh
```

The packaged app will be generated at `dist/SyncTwin.app`.

## How To Use

1. Install and launch the same version of `SyncTwin` on both Macs.
2. Select the local directory to sync on each side.
3. Connect to the other Mac in the "Peer Connection" section.
4. After version validation completes, click "Sync Now" manually or enable auto-sync.
5. If a conflict appears, open the local version or the remote snapshot in "Pending Conflicts" and decide which one to keep.

## Current Boundaries

- The current implementation mainly targets small- to medium-sized directories such as documents, code, and configuration files.
- Single-file transfer currently uses inline data messages with a default limit of 32 MB; files beyond that limit are blocked from syncing and require manual handling.
- The test directory already includes reserved sync-planning test cases; more tests can be added and run when the local toolchain is fully available.
