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
            initiator: initiator,
            responder: responder
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
            initiator: ["doc.md": changed],
            responder: ["doc.md": changed]
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
            initiator: ["spreadsheet.csv": fingerprint(hash: "left")],
            responder: ["spreadsheet.csv": fingerprint(hash: "right")]
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
            initiator: [:],
            responder: ["archive.zip": fingerprint(hash: "newer")]
        )

        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(plan.conflicts.count, 1)
        XCTAssertEqual(plan.conflicts.first?.reason, .modifyVsDelete)
    }

    private func fingerprint(hash: String) -> FileFingerprint {
        FileFingerprint(
            contentHash: hash,
            size: Int64(hash.count),
            modifiedAt: Date(timeIntervalSince1970: 1_717_171_717)
        )
    }
}
