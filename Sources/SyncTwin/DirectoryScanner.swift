import CryptoKit
import Foundation

enum DirectoryScannerError: LocalizedError {
    case noFolderConfigured
    case fileTooLarge(String)
    case unexpectedFileMissing(String)

    var errorDescription: String? {
        switch self {
        case .noFolderConfigured:
            return "请先选择需要同步的目录。"
        case let .fileTooLarge(path):
            return "文件 \(path) 超过当前版本的单文件内联传输上限（32 MB）。"
        case let .unexpectedFileMissing(path):
            return "读取文件 \(path) 时未找到内容。"
        }
    }
}

struct DirectoryScanner {
    private let fileManager = FileManager.default
    private let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .contentModificationDateKey,
        .fileSizeKey,
    ]

    func scan(
        root: URL,
        cachedFiles: [String: FileFingerprint],
        baseline: [String: FileFingerprint]
    ) throws -> LocalScanResult {
        guard fileManager.fileExists(atPath: root.path) else {
            throw DirectoryScannerError.noFolderConfigured
        }

        let scannedAt = Date()
        let scan = try enumerateEntries(
            at: root,
            root: root,
            cachedFiles: cachedFiles
        )

        return makeScanResult(
            files: scan.files,
            baseline: baseline,
            scannedAt: scannedAt,
            mode: .full,
            filesystemWorkUnits: max(1, scan.workUnits),
            dirtyPathCount: max(1, scan.files.count)
        )
    }

    func scanIncremental(
        root: URL,
        cachedFiles: [String: FileFingerprint],
        baseline: [String: FileFingerprint],
        dirtyPaths: [DirectoryDirtyPath]
    ) throws -> LocalScanResult {
        guard fileManager.fileExists(atPath: root.path) else {
            throw DirectoryScannerError.noFolderConfigured
        }

        let normalizedDirtyPaths = normalizeDirtyPaths(dirtyPaths)
        if normalizedDirtyPaths.contains(where: { $0.scope == .subtree && $0.path.isEmpty }) {
            return try scan(root: root, cachedFiles: cachedFiles, baseline: baseline)
        }

        let scannedAt = Date()
        var files = cachedFiles
        var filesystemWorkUnits = 0

        for dirtyPath in normalizedDirtyPaths {
            filesystemWorkUnits += try refreshCachedEntries(
                &files,
                root: root,
                dirtyPath: dirtyPath
            )
        }

        return makeScanResult(
            files: files,
            baseline: baseline,
            scannedAt: scannedAt,
            mode: .incremental,
            filesystemWorkUnits: max(filesystemWorkUnits, normalizedDirtyPaths.isEmpty ? 0 : 1),
            dirtyPathCount: normalizedDirtyPaths.count
        )
    }

    func scanCurrentFiles(root: URL) throws -> [String: FileFingerprint] {
        guard fileManager.fileExists(atPath: root.path) else {
            throw DirectoryScannerError.noFolderConfigured
        }

        return try enumerateEntries(at: root, root: root, cachedFiles: [:]).files
    }

    func currentState(root: URL, relativePath: String) throws -> FileFingerprint? {
        let url = absoluteURL(root: root, relativePath: relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try itemState(for: url)
    }

    func bundleFile(root: URL, relativePath: String, expectedState: FileFingerprint) throws -> BundledFile {
        guard !expectedState.isDirectory else {
            throw DirectoryScannerError.unexpectedFileMissing(relativePath)
        }
        let url = absoluteURL(root: root, relativePath: relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw DirectoryScannerError.unexpectedFileMissing(relativePath)
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if fileSize > AppConstants.maxInlineFileBytes {
            throw DirectoryScannerError.fileTooLarge(relativePath)
        }

        let data = try Data(contentsOf: url)
        let actual = try fingerprint(for: url)
        guard equivalentState(actual, expectedState) else {
            throw DirectoryScannerError.unexpectedFileMissing(relativePath)
        }

        return BundledFile(path: relativePath, fingerprint: actual, data: data)
    }

    func writeFile(_ file: BundledFile, into root: URL) throws {
        let targetURL = absoluteURL(root: root, relativePath: file.path)
        let parent = targetURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try replaceDirectoryIfNeeded(at: targetURL)
        try file.data.write(to: targetURL, options: .atomic)
        let date = file.fingerprint.modifiedAt
        try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: targetURL.path)
    }

    func writeData(_ data: Data, to root: URL, relativePath: String, modifiedAt: Date? = nil) throws {
        let targetURL = absoluteURL(root: root, relativePath: relativePath)
        let parent = targetURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try replaceDirectoryIfNeeded(at: targetURL)
        try data.write(to: targetURL, options: .atomic)
        if let modifiedAt {
            try? fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: targetURL.path)
        }
    }

    func deleteItem(root: URL, relativePath: String) throws {
        let targetURL = absoluteURL(root: root, relativePath: relativePath)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return
        }
        try fileManager.removeItem(at: targetURL)
    }

    func absoluteURL(root: URL, relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    private func makeScanResult(
        files: [String: FileFingerprint],
        baseline: [String: FileFingerprint],
        scannedAt: Date,
        mode: DirectoryScanMode,
        filesystemWorkUnits: Int,
        dirtyPathCount: Int
    ) -> LocalScanResult {
        var changedFiles: [String: FileFingerprint] = [:]
        for (path, fingerprint) in files where !equivalentState(fingerprint, baseline[path]) {
            changedFiles[path] = fingerprint
        }

        let deletedPaths = baseline.keys
            .filter { files[$0] == nil }
            .sorted()

        return LocalScanResult(
            manifest: DirectoryManifest(scannedAt: scannedAt, files: files),
            delta: DirectoryDeltaManifest(
                scannedAt: scannedAt,
                changedFiles: changedFiles,
                deletedPaths: deletedPaths
            ),
            mode: mode,
            filesystemWorkUnits: filesystemWorkUnits,
            dirtyPathCount: dirtyPathCount
        )
    }

    private func normalizeDirtyPaths(_ dirtyPaths: [DirectoryDirtyPath]) -> [DirectoryDirtyPath] {
        var normalized: [DirectoryDirtyPath] = []

        for dirtyPath in dirtyPaths.sorted(by: dirtyPathComparator) {
            if normalized.contains(where: { $0.scope == .subtree && isEqualOrDescendantPath(dirtyPath.path, of: $0.path) }) {
                continue
            }

            if dirtyPath.scope == .subtree {
                normalized.removeAll { isEqualOrDescendantPath($0.path, of: dirtyPath.path) }
            } else if let index = normalized.firstIndex(where: { $0.path == dirtyPath.path }) {
                if normalized[index].lastEventID >= dirtyPath.lastEventID {
                    continue
                }
                normalized[index] = dirtyPath
                continue
            }

            normalized.append(dirtyPath)
        }

        return normalized.sorted(by: dirtyPathComparator)
    }

    private func dirtyPathComparator(_ lhs: DirectoryDirtyPath, _ rhs: DirectoryDirtyPath) -> Bool {
        if lhs.path.count != rhs.path.count {
            return lhs.path.count < rhs.path.count
        }
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        return lhs.scope == .subtree && rhs.scope == .file
    }

    private func refreshCachedEntries(
        _ files: inout [String: FileFingerprint],
        root: URL,
        dirtyPath: DirectoryDirtyPath
    ) throws -> Int {
        switch dirtyPath.scope {
        case .file:
            return try refreshExactPath(&files, root: root, relativePath: dirtyPath.path)
        case .subtree:
            return try refreshSubtree(&files, root: root, relativePath: dirtyPath.path)
        }
    }

    private func refreshExactPath(
        _ files: inout [String: FileFingerprint],
        root: URL,
        relativePath: String
    ) throws -> Int {
        let cachedSnapshot = files
        let url = absoluteURL(root: root, relativePath: relativePath)

        guard fileManager.fileExists(atPath: url.path) else {
            removeEntries(in: &files, matching: relativePath)
            return 1
        }

        let values = try url.resourceValues(forKeys: resourceKeys)
        if values.isDirectory == true {
            return try refreshSubtree(&files, root: root, relativePath: relativePath)
        }
        if values.isSymbolicLink == true || values.isRegularFile != true {
            removeEntries(in: &files, matching: relativePath)
            return 1
        }

        removeDescendants(of: relativePath, in: &files)

        let modifiedAt = values.contentModificationDate ?? Date.distantPast
        let size = Int64(values.fileSize ?? 0)
        if let cached = cachedSnapshot[relativePath],
           cached.size == size,
           cached.modifiedAt == modifiedAt {
            files[relativePath] = cached
        } else {
            files[relativePath] = try fingerprint(for: url, modifiedAt: modifiedAt, size: size)
        }
        return 1
    }

    private func refreshSubtree(
        _ files: inout [String: FileFingerprint],
        root: URL,
        relativePath: String
    ) throws -> Int {
        let cachedSnapshot = files
        let url = relativePath.isEmpty ? root : absoluteURL(root: root, relativePath: relativePath)

        guard fileManager.fileExists(atPath: url.path) else {
            removeEntries(in: &files, matching: relativePath)
            return 1
        }

        let values = try url.resourceValues(forKeys: resourceKeys)
        if values.isSymbolicLink == true {
            removeEntries(in: &files, matching: relativePath)
            return 1
        }

        if values.isRegularFile == true {
            removeEntries(in: &files, matching: relativePath)

            let modifiedAt = values.contentModificationDate ?? Date.distantPast
            let size = Int64(values.fileSize ?? 0)
            if let cached = cachedSnapshot[relativePath],
               cached.size == size,
               cached.modifiedAt == modifiedAt {
                files[relativePath] = cached
            } else {
                files[relativePath] = try fingerprint(for: url, modifiedAt: modifiedAt, size: size)
            }
            return 1
        }

        guard values.isDirectory == true else {
            removeEntries(in: &files, matching: relativePath)
            return 1
        }

        let subtreeScan = try enumerateEntries(at: url, root: root, cachedFiles: cachedSnapshot)
        removeEntries(in: &files, matching: relativePath)
        files.merge(subtreeScan.files) { _, new in new }
        return max(1, subtreeScan.workUnits)
    }

    private func enumerateEntries(
        at directoryURL: URL,
        root: URL,
        cachedFiles: [String: FileFingerprint]
    ) throws -> (files: [String: FileFingerprint], workUnits: Int) {
        var files: [String: FileFingerprint] = [:]
        var workUnits = 0

        if directoryURL != root {
            let rootValues = try directoryURL.resourceValues(forKeys: resourceKeys)
            if rootValues.isSymbolicLink == true || rootValues.isDirectory != true {
                return (files, 1)
            }
            let directoryPath = relativePath(for: directoryURL, under: root)
            files[directoryPath] = directoryFingerprint(for: rootValues)
            workUnits += 1
        }

        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ) else {
            return (files, max(1, workUnits))
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isSymbolicLink == true {
                continue
            }
            if values.isDirectory == true {
                workUnits += 1
                let directoryPath = relativePath(for: url, under: root)
                files[directoryPath] = directoryFingerprint(for: values)
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }

            workUnits += 1
            let relativePath = relativePath(for: url, under: root)
            let modifiedAt = values.contentModificationDate ?? Date.distantPast
            let size = Int64(values.fileSize ?? 0)

            if let cached = cachedFiles[relativePath],
               cached.size == size,
               cached.modifiedAt == modifiedAt {
                files[relativePath] = cached
            } else {
                files[relativePath] = try fingerprint(for: url, modifiedAt: modifiedAt, size: size)
            }
        }

        return (files, max(1, workUnits))
    }

    private func removeEntries(
        in files: inout [String: FileFingerprint],
        matching relativePath: String
    ) {
        if relativePath.isEmpty {
            files.removeAll()
            return
        }

        files = files.filter { path, _ in
            !isEqualOrDescendantPath(path, of: relativePath)
        }
    }

    private func removeDescendants(
        of relativePath: String,
        in files: inout [String: FileFingerprint]
    ) {
        guard !relativePath.isEmpty else {
            return
        }

        files = files.filter { path, _ in
            path == relativePath || !path.hasPrefix(relativePath + "/")
        }
    }

    private func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let offset = rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1
        return String(filePath.dropFirst(offset))
    }

    private func itemState(for url: URL) throws -> FileFingerprint {
        let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        if resourceValues.isDirectory == true {
            return directoryFingerprint(for: resourceValues)
        }
        let modifiedAt = resourceValues.contentModificationDate ?? Date.distantPast
        let size = Int64(resourceValues.fileSize ?? 0)
        return try fingerprint(for: url, modifiedAt: modifiedAt, size: size)
    }

    private func fingerprint(for url: URL) throws -> FileFingerprint {
        let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = resourceValues.contentModificationDate ?? Date.distantPast
        let size = Int64(resourceValues.fileSize ?? 0)
        return try fingerprint(for: url, modifiedAt: modifiedAt, size: size)
    }

    private func fingerprint(for url: URL, modifiedAt: Date, size: Int64) throws -> FileFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = Insecure.MD5()
        while true {
            guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileFingerprint(contentHash: digest, size: size, modifiedAt: modifiedAt, isDirectory: false)
    }

    func writeDirectory(root: URL, relativePath: String, modifiedAt: Date? = nil) throws {
        let targetURL = absoluteURL(root: root, relativePath: relativePath)
        try replaceFileIfNeeded(at: targetURL)
        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
        if let modifiedAt {
            try? fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: targetURL.path)
        }
    }

    private func replaceDirectoryIfNeeded(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func replaceFileIfNeeded(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func directoryFingerprint(for values: URLResourceValues) -> FileFingerprint {
        FileFingerprint(
            contentHash: "__directory__",
            size: 0,
            modifiedAt: values.contentModificationDate ?? Date.distantPast,
            isDirectory: true
        )
    }
}
