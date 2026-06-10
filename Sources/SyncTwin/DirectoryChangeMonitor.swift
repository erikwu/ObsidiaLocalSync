import CoreServices
import Foundation

private let directoryMonitorInvalidatingFlags = FSEventStreamEventFlags(
    kFSEventStreamEventFlagKernelDropped
        | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagRootChanged
        | kFSEventStreamEventFlagMount
        | kFSEventStreamEventFlagUnmount
)

private let directoryMonitorItemIsFileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
private let directoryMonitorItemIsDirectoryFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
private let directoryMonitorItemIsSymlinkFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsSymlink)
private let directoryMonitorItemRenamedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)

final class DirectoryChangeMonitor {
    private let storage: AppStorage
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "SyncTwin.DirectoryChangeMonitor")

    private var stream: FSEventStreamRef?
    private var monitoredRootURL: URL?
    private var journal = DirectoryChangeJournal()

    init(storage: AppStorage) {
        self.storage = storage
    }

    deinit {
        stop()
    }

    func startMonitoring(root: URL) {
        let normalizedRoot = root.standardizedFileURL
        queue.sync {
            guard monitoredRootURL?.path != normalizedRoot.path || stream == nil else {
                return
            }

            stopLocked()
            monitoredRootURL = normalizedRoot
            journal = storage.loadDirectoryChangeJournal(rootPath: normalizedRoot.path)

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: normalizedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return
            }

            var context = FSEventStreamContext(
                version: 0,
                info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let sinceWhen: FSEventStreamEventId = journal.lastObservedEventID > 0
                ? FSEventStreamEventId(journal.lastObservedEventID)
                : FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
            )

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                directoryChangeMonitorCallback,
                &context,
                [normalizedRoot.path] as CFArray,
                sinceWhen,
                0.5,
                flags
            ) else {
                return
            }

            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return
            }

            self.stream = stream
        }
    }

    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    func flushPendingEvents(for root: URL) {
        let normalizedRoot = root.standardizedFileURL
        queue.sync {
            guard monitoredRootURL?.path == normalizedRoot.path, let stream else {
                return
            }
            FSEventStreamFlushSync(stream)
        }
    }

    func journalSnapshot(for root: URL) -> DirectoryChangeJournal {
        let normalizedRoot = root.standardizedFileURL
        return queue.sync {
            if monitoredRootURL?.path == normalizedRoot.path {
                return journal
            }
            return storage.loadDirectoryChangeJournal(rootPath: normalizedRoot.path)
        }
    }

    @discardableResult
    func markSynchronizedAndCaptureEventID(for root: URL) -> UInt64 {
        let normalizedRoot = root.standardizedFileURL
        return queue.sync {
            let eventID: UInt64

            if monitoredRootURL?.path == normalizedRoot.path, let stream {
                FSEventStreamFlushSync(stream)
                eventID = UInt64(FSEventStreamGetLatestEventId(stream))
                journal.markHealthy(observedEventID: eventID)
                saveCurrentJournalLocked()
            } else {
                eventID = UInt64(FSEventsGetCurrentEventId())
                var storedJournal = storage.loadDirectoryChangeJournal(rootPath: normalizedRoot.path)
                storedJournal.markHealthy(observedEventID: eventID)
                try? storage.saveDirectoryChangeJournal(storedJournal, rootPath: normalizedRoot.path)
            }

            return eventID
        }
    }

    private func stopLocked() {
        guard let stream else {
            monitoredRootURL = nil
            journal = DirectoryChangeJournal()
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        monitoredRootURL = nil
        journal = DirectoryChangeJournal()
    }

    fileprivate func handleEventBatch(
        count: Int,
        rawPaths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>,
        eventIDs: UnsafePointer<FSEventStreamEventId>
    ) {
        guard let rootPath = monitoredRootURL?.path else {
            return
        }

        let paths = Unmanaged<NSArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
        guard !paths.isEmpty else {
            return
        }

        var snapshot = journal

        for index in 0..<min(count, paths.count) {
            let eventID = UInt64(eventIDs[index])
            let flag = flags[index]

            if flag & directoryMonitorInvalidatingFlags != 0 {
                snapshot.noteFullRescanRequired(observedEventID: eventID)
                continue
            }

            guard let relativePath = relativePath(for: paths[index], under: rootPath) else {
                snapshot.noteObservedEventID(eventID)
                continue
            }

            let dirtyPath = dirtyPathSelection(for: relativePath, flags: flag)
            snapshot.recordChange(path: dirtyPath.path, scope: dirtyPath.scope, eventID: eventID)
        }

        journal = snapshot
        saveCurrentJournalLocked()
    }

    private func saveCurrentJournalLocked() {
        guard let monitoredRootURL else {
            return
        }
        try? storage.saveDirectoryChangeJournal(journal, rootPath: monitoredRootURL.path)
    }

    private func relativePath(for absolutePath: String, under rootPath: String) -> String? {
        let standardizedAbsolutePath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        if standardizedAbsolutePath == rootPath {
            return ""
        }

        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard standardizedAbsolutePath.hasPrefix(prefix) else {
            return nil
        }
        return String(standardizedAbsolutePath.dropFirst(prefix.count))
    }

    private func dirtyPathSelection(
        for relativePath: String,
        flags: FSEventStreamEventFlags
    ) -> (path: String, scope: DirtyPathScope) {
        let normalizedPath = normalizedRelativePath(relativePath)

        if flags & directoryMonitorItemIsDirectoryFlag != 0 {
            return (normalizedPath, .subtree)
        }

        if flags & directoryMonitorItemRenamedFlag != 0 {
            return (parentRelativePath(of: normalizedPath), .subtree)
        }

        if flags & directoryMonitorItemIsFileFlag != 0 || flags & directoryMonitorItemIsSymlinkFlag != 0 {
            return (normalizedPath, .file)
        }

        return (parentRelativePath(of: normalizedPath), .subtree)
    }
}

private func directoryChangeMonitorCallback(
    _: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) -> Void {
    guard let info else {
        return
    }

    let monitor = Unmanaged<DirectoryChangeMonitor>.fromOpaque(info).takeUnretainedValue()
    monitor.handleEventBatch(
        count: numEvents,
        rawPaths: eventPaths,
        flags: eventFlags,
        eventIDs: eventIds
    )
}
