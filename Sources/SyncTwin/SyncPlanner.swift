import Foundation

struct SyncPlanner {
    func makePlan(
        requestID: UUID,
        baseline: [String: FileFingerprint],
        initiatorDelta: DirectoryDeltaManifest,
        responderDelta: DirectoryDeltaManifest
    ) -> SyncPlan {
        let allPaths = Set(initiatorDelta.changedFiles.keys)
            .union(initiatorDelta.deletedPaths)
            .union(responderDelta.changedFiles.keys)
            .union(responderDelta.deletedPaths)
            .sorted()

        var operations: [SyncOperation] = []
        var conflicts: [SyncConflict] = []
        var baselineChanges: [BaselineChange] = []

        for path in allPaths {
            let baselineState = baseline[path]
            let initiatorState = initiatorDelta.resolvedState(for: path, baselineState: baselineState)
            let responderState = responderDelta.resolvedState(for: path, baselineState: baselineState)

            let initiatorChanged = initiatorDelta.hasChange(at: path)
            let responderChanged = responderDelta.hasChange(at: path)

            switch (initiatorChanged, responderChanged) {
            case (false, false):
                continue

            case (true, false):
                let change = planSingleSidedChange(
                    path: path,
                    sourceSide: .initiator,
                    sourceState: initiatorState,
                    targetState: responderState
                )
                operations.append(change.operation)
                baselineChanges.append(BaselineChange(path: path, resultingState: initiatorState))

            case (false, true):
                let change = planSingleSidedChange(
                    path: path,
                    sourceSide: .responder,
                    sourceState: responderState,
                    targetState: initiatorState
                )
                operations.append(change.operation)
                baselineChanges.append(BaselineChange(path: path, resultingState: responderState))

            case (true, true):
                if equivalentState(initiatorState, responderState) {
                    baselineChanges.append(BaselineChange(path: path, resultingState: initiatorState))
                } else {
                    conflicts.append(
                        SyncConflict(
                            id: UUID(),
                            path: path,
                            reason: conflictReason(
                                baseline: baselineState,
                                initiator: initiatorState,
                                responder: responderState
                            ),
                            baselineState: baselineState,
                            initiatorState: initiatorState,
                            responderState: responderState
                        )
                    )
                }
            }
        }

        return SyncPlan(
            requestID: requestID,
            operations: operations,
            conflicts: conflicts,
            baselineChanges: baselineChanges
        )
    }

    private func planSingleSidedChange(
        path: String,
        sourceSide: PlanRole,
        sourceState: FileFingerprint?,
        targetState: FileFingerprint?
    ) -> (operation: SyncOperation, resultingState: FileFingerprint?) {
        let targetSide: PlanRole = sourceSide == .initiator ? .responder : .initiator
        let operation = SyncOperation(
            path: path,
            target: targetSide,
            source: sourceState == nil ? nil : sourceSide,
            expectedInitiatorState: sourceSide == .initiator ? sourceState : targetState,
            expectedResponderState: sourceSide == .responder ? sourceState : targetState,
            resultingState: sourceState
        )
        return (operation, sourceState)
    }

    private func conflictReason(
        baseline: FileFingerprint?,
        initiator: FileFingerprint?,
        responder: FileFingerprint?
    ) -> ConflictReason {
        if baseline == nil {
            return .bothCreatedDifferently
        }
        if initiator == nil || responder == nil {
            return .modifyVsDelete
        }
        return .bothModified
    }
}
