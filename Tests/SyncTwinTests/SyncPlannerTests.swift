import Foundation
import XCTest
@testable import SyncTwin

final class SyncPlannerTests: XCTestCase {
    private let planner = SyncPlanner()

    func testSingleSidedUpdateCopiesToOtherSide() {
        let baseline = ["notes.txt": fingerprint(hash: "old")]
        let initiator = ["notes.txt": fingerprint(hash: "newer")]
        let responder = ["notes.txt": fingerprint(hash: "old")]

        let plan = planner.makePlan(
            requestID: UUID(),
            baseline: baseline,
            initiatorDelta: delta(changed: initiator),
            responderDelta: delta(changed: responder)
        )

        XCTAssertEqual(plan.operations.count, 1)
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(plan.operations.first?.target, .responder)
        XCTAssertEqual(plan.operations.first?.source, .initiator)
        XCTAssertEqual(plan.baselineChanges.first?.resultingState, initiator["notes.txt"])
    }

    func testIdenticalChangesOnBothSidesDoNotPromptHuman() {
        let baseline = ["doc.md": fingerprint(hash: "old")]
        let changed = fingerprint(hash: "same-new")

        let plan = planner.makePlan(
            requestID: UUID(),
            baseline: baseline,
            initiatorDelta: delta(changed: ["doc.md": changed]),
            responderDelta: delta(changed: ["doc.md": changed])
        )

        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(plan.baselineChanges, [BaselineChange(path: "doc.md", resultingState: changed)])
    }

    func testDivergentEditsBecomeConflict() {
        let baseline = ["spreadsheet.csv": fingerprint(hash: "old")]

        let plan = planner.makePlan(
            requestID: UUID(),
            baseline: baseline,
            initiatorDelta: delta(changed: ["spreadsheet.csv": fingerprint(hash: "left")]),
            responderDelta: delta(changed: ["spreadsheet.csv": fingerprint(hash: "right")])
        )

        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(plan.conflicts.count, 1)
        XCTAssertEqual(plan.conflicts.first?.reason, .bothModified)
    }

    func testDeleteVsModifyRequiresManualDecision() {
        let baseline = ["archive.zip": fingerprint(hash: "old")]

        let plan = planner.makePlan(
            requestID: UUID(),
            baseline: baseline,
            initiatorDelta: delta(deleted: ["archive.zip"]),
            responderDelta: delta(changed: ["archive.zip": fingerprint(hash: "newer")])
        )

        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(plan.conflicts.count, 1)
        XCTAssertEqual(plan.conflicts.first?.reason, .modifyVsDelete)
    }

    func testSingleSidedDirectoryCreationCopiesToOtherSide() {
        let createdDirectory = directoryFingerprint()

        let plan = planner.makePlan(
            requestID: UUID(),
            baseline: [:],
            initiatorDelta: delta(changed: ["folder/subfolder": createdDirectory]),
            responderDelta: delta()
        )

        XCTAssertEqual(plan.operations.count, 1)
        XCTAssertEqual(plan.operations.first?.target, .responder)
        XCTAssertEqual(plan.operations.first?.resultingState, createdDirectory)
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func testDirectoryAndFileWithSamePathConflict() {
        let plan = planner.makePlan(
            requestID: UUID(),
            baseline: [:],
            initiatorDelta: delta(changed: ["workspace": directoryFingerprint()]),
            responderDelta: delta(changed: ["workspace": fingerprint(hash: "file")])
        )

        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(plan.conflicts.count, 1)
        XCTAssertEqual(plan.conflicts.first?.reason, .bothCreatedDifferently)
    }

    func testPlannerIgnoresDSStoreChanges() {
        let dsStore = fingerprint(hash: "finder")

        let plan = planner.makePlan(
            requestID: UUID(),
            baseline: [".DS_Store": dsStore],
            initiatorDelta: delta(changed: [".DS_Store": dsStore], deleted: [".DS_Store"]),
            responderDelta: delta(changed: [".DS_Store": dsStore], deleted: [".DS_Store"])
        )

        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertTrue(plan.baselineChanges.isEmpty)
    }

    func testCompleteWipeRestoresInitiatorInsteadOfDeletingResponder() {
        let baseline = baselineFiles(count: 6)
        let deletedPaths = baseline.keys.sorted()

        let plan = planner.makePlan(
            requestID: UUID(),
            baseline: baseline,
            initiatorDelta: delta(deleted: deletedPaths),
            responderDelta: delta()
        )

        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(plan.operations.count, baseline.count)
        XCTAssertTrue(plan.operations.allSatisfy { $0.target == .initiator })
        XCTAssertTrue(plan.operations.allSatisfy { $0.source == .responder })
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: plan.baselineChanges.map { ($0.path, $0.resultingState) }),
            baseline
        )
    }

    func testCompleteWipeRestoresResponderInsteadOfDeletingInitiator() {
        let baseline = baselineFiles(count: 6)
        let deletedPaths = baseline.keys.sorted()

        let plan = planner.makePlan(
            requestID: UUID(),
            baseline: baseline,
            initiatorDelta: delta(),
            responderDelta: delta(deleted: deletedPaths)
        )

        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(plan.operations.count, baseline.count)
        XCTAssertTrue(plan.operations.allSatisfy { $0.target == .responder })
        XCTAssertTrue(plan.operations.allSatisfy { $0.source == .initiator })
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: plan.baselineChanges.map { ($0.path, $0.resultingState) }),
            baseline
        )
    }

    func testNearEmptyMassDeletionRecoversRemainingBaselineFromHealthySide() {
        let baseline = baselineFiles(count: 100)
        let deletedPaths = baseline.keys.sorted().dropLast(5)

        let plan = planner.makePlan(
            requestID: UUID(),
            baseline: baseline,
            initiatorDelta: delta(),
            responderDelta: delta(deleted: Array(deletedPaths))
        )

        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(plan.operations.count, deletedPaths.count)
        XCTAssertTrue(plan.operations.allSatisfy { $0.target == .responder })
        XCTAssertTrue(plan.operations.allSatisfy { $0.source == .initiator })
    }

    func testOrdinarySingleDeleteStillPropagatesDeletion() {
        let baseline = baselineFiles(count: 2)
        let deletedPath = "file-0.txt"

        let plan = planner.makePlan(
            requestID: UUID(),
            baseline: baseline,
            initiatorDelta: delta(deleted: [deletedPath]),
            responderDelta: delta()
        )

        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(plan.operations.count, 1)
        XCTAssertEqual(plan.operations.first?.path, deletedPath)
        XCTAssertEqual(plan.operations.first?.target, .responder)
        XCTAssertNil(plan.operations.first?.source)
        XCTAssertNil(plan.operations.first?.resultingState)
    }

    private func fingerprint(hash: String) -> FileFingerprint {
        FileFingerprint(
            contentHash: hash,
            size: Int64(hash.count),
            modifiedAt: Date(timeIntervalSince1970: 1_717_171_717)
        )
    }

    private func directoryFingerprint() -> FileFingerprint {
        FileFingerprint(
            contentHash: "__directory__",
            size: 0,
            modifiedAt: Date(timeIntervalSince1970: 1_717_171_717),
            isDirectory: true
        )
    }

    private func baselineFiles(count: Int) -> [String: FileFingerprint] {
        Dictionary(
            uniqueKeysWithValues: (0..<count).map { index in
                ("file-\(index).txt", fingerprint(hash: "baseline-\(index)"))
            }
        )
    }

    private func delta(
        changed: [String: FileFingerprint] = [:],
        deleted: [String] = []
    ) -> DirectoryDeltaManifest {
        DirectoryDeltaManifest(
            scannedAt: Date(timeIntervalSince1970: 1_717_171_717),
            changedFiles: changed,
            deletedPaths: deleted
        )
    }
}
