import Foundation
import XCTest
@testable import SyncTwin

final class DirectoryScannerTests: XCTestCase {
    func testBundleFileSupportsFilesLargerThanThirtyTwoMegabytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncTwinTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let relativePath = "large.bin"
        let fileURL = root.appendingPathComponent(relativePath)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }

        let targetSize = 33 * 1_024 * 1_024
        let chunk = Data(repeating: 0x5A, count: 1_024 * 1_024)
        for _ in 0..<33 {
            try handle.write(contentsOf: chunk)
        }

        let scanner = DirectoryScanner()
        let expectedState = try XCTUnwrap(scanner.currentState(root: root, relativePath: relativePath))
        let bundled = try scanner.bundleFile(root: root, relativePath: relativePath, expectedState: expectedState)

        XCTAssertEqual(bundled.path, relativePath)
        XCTAssertEqual(bundled.data.count, targetSize)
        XCTAssertTrue(equivalentState(bundled.fingerprint, expectedState))
    }

    func testFileTransferChunkMessagesRoundTripThroughCodec() throws {
        let requestID = UUID()
        let fingerprint = FileFingerprint(
            contentHash: "abc123",
            size: 1_024,
            modifiedAt: Date(timeIntervalSince1970: 1_717_171_717)
        )
        let payload = FileTransferChunkMessage(
            requestID: requestID,
            path: "folder/note.md",
            chunkIndex: 2,
            totalChunks: 4,
            data: Data("chunk-data".utf8)
        )

        let encoded = try SyncMessageCodec.encode(payload, kind: .fileTransferChunk)
        let envelope = try SyncMessageCodec.decodeEnvelope(from: encoded)
        let decoded = try SyncMessageCodec.decodePayload(FileTransferChunkMessage.self, from: envelope)

        XCTAssertEqual(envelope.kind, .fileTransferChunk)
        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.path, "folder/note.md")
        XCTAssertEqual(decoded.chunkIndex, 2)
        XCTAssertEqual(decoded.totalChunks, 4)
        XCTAssertEqual(decoded.data, Data("chunk-data".utf8))

        let start = FileTransferStartMessage(
            requestID: requestID,
            files: [TransferredFileDescriptor(path: "folder/note.md", fingerprint: fingerprint)],
            failures: []
        )
        let startEncoded = try SyncMessageCodec.encode(start, kind: .fileTransferStart)
        let startEnvelope = try SyncMessageCodec.decodeEnvelope(from: startEncoded)
        let startDecoded = try SyncMessageCodec.decodePayload(FileTransferStartMessage.self, from: startEnvelope)

        XCTAssertEqual(startEnvelope.kind, .fileTransferStart)
        XCTAssertEqual(startDecoded.files.first?.fingerprint, fingerprint)
        XCTAssertEqual(startDecoded.files.first?.path, "folder/note.md")
    }
}
