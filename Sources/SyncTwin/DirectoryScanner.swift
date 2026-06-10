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

    func scan(root: URL) throws -> DirectoryManifest {
        guard fileManager.fileExists(atPath: root.path) else {
            throw DirectoryScannerError.noFolderConfigured
        }

        var files: [String: FileFingerprint] = [:]
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ) else {
            return DirectoryManifest(scannedAt: Date(), files: files)
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isSymbolicLink == true {
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }

            let relativePath = relativePath(for: url, under: root)
            files[relativePath] = try fingerprint(for: url)
        }

        return DirectoryManifest(scannedAt: Date(), files: files)
    }

    func currentState(root: URL, relativePath: String) throws -> FileFingerprint? {
        let url = absoluteURL(root: root, relativePath: relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try fingerprint(for: url)
    }

    func bundleFile(root: URL, relativePath: String, expectedState: FileFingerprint) throws -> BundledFile {
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
        try file.data.write(to: targetURL, options: .atomic)
        let date = file.fingerprint.modifiedAt
        try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: targetURL.path)
    }

    func writeData(_ data: Data, to root: URL, relativePath: String, modifiedAt: Date? = nil) throws {
        let targetURL = absoluteURL(root: root, relativePath: relativePath)
        let parent = targetURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
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

    private func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let offset = rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1
        return String(filePath.dropFirst(offset))
    }

    private func fingerprint(for url: URL) throws -> FileFingerprint {
        let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = resourceValues.contentModificationDate ?? Date.distantPast
        let size = Int64(resourceValues.fileSize ?? 0)

        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileFingerprint(contentHash: digest, size: size, modifiedAt: modifiedAt)
    }
}
