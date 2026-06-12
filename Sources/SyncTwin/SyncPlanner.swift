import Foundation

struct SyncPlanner {
    func recoveryCandidates(
        baseline: [String: FileFingerprint],
        initiatorDelta: DirectoryDeltaManifest,
        responderDelta: DirectoryDeltaManifest
    ) -> Set<PlanRole> {
        let baselineCount = baseline.keys.filter { !shouldIgnoreSyncRelativePath($0) }.count
        guard baselineCount > 0 else {
            return []
        }

        let initiatorSignal = massDeletionSignal(
            role: .initiator,
            baseline: baseline,
            delta: initiatorDelta
        )
        let responderSignal = massDeletionSignal(
            role: .responder,
            baseline: baseline,
            delta: responderDelta
        )

        return Set(
            [initiatorSignal, responderSignal]
                .filter(\.isRecoveryCandidate)
                .map(\.role)
        )
    }

    func makePlan(
        requestID: UUID,
        baseline: [String: FileFingerprint],
        initiatorDelta: DirectoryDeltaManifest,
        responderDelta: DirectoryDeltaManifest
    ) -> SyncPlan {
        let recoveryCandidates = recoveryCandidates(
            baseline: baseline,
            initiatorDelta: initiatorDelta,
            responderDelta: responderDelta
        )
        let allPaths = Set(initiatorDelta.changedFiles.keys)
            .union(initiatorDelta.deletedPaths)
            .union(responderDelta.changedFiles.keys)
            .union(responderDelta.deletedPaths)
            .filter { !shouldIgnoreSyncRelativePath($0) }
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

            if let recoveredChange = recoveredSingleSidedChange(
                path: path,
                initiatorChanged: initiatorChanged,
                responderChanged: responderChanged,
                initiatorState: initiatorState,
                responderState: responderState,
                recoveryCandidates: recoveryCandidates
            ) {
                operations.append(recoveredChange.operation)
                baselineChanges.append(BaselineChange(path: path, resultingState: recoveredChange.resultingState))
                continue
            }

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

    private func recoveredSingleSidedChange(
        path: String,
        initiatorChanged: Bool,
        responderChanged: Bool,
        initiatorState: FileFingerprint?,
        responderState: FileFingerprint?,
        recoveryCandidates: Set<PlanRole>
    ) -> (operation: SyncOperation, resultingState: FileFingerprint?)? {
        if recoveryCandidates.contains(.initiator),
           initiatorChanged,
           initiatorState == nil,
           let responderState {
            return planSingleSidedChange(
                path: path,
                sourceSide: .responder,
                sourceState: responderState,
                targetState: nil
            )
        }

        if recoveryCandidates.contains(.responder),
           responderChanged,
           responderState == nil,
           let initiatorState {
            return planSingleSidedChange(
                path: path,
                sourceSide: .initiator,
                sourceState: initiatorState,
                targetState: nil
            )
        }

        return nil
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

    private func massDeletionSignal(
        role: PlanRole,
        baseline: [String: FileFingerprint],
        delta: DirectoryDeltaManifest
    ) -> MassDeletionSignal {
        let filteredBaseline = baseline.filter { !shouldIgnoreSyncRelativePath($0.key) }
        let deletedBaselineCount = delta.deletedPaths.reduce(into: 0) { count, path in
            if filteredBaseline[path] != nil {
                count += 1
            }
        }
        let modifiedBaselineCount = delta.changedFiles.keys.reduce(into: 0) { count, path in
            if filteredBaseline[path] != nil {
                count += 1
            }
        }
        let newPathCount = delta.changedFiles.keys.reduce(into: 0) { count, path in
            if filteredBaseline[path] == nil {
                count += 1
            }
        }

        return MassDeletionSignal(
            role: role,
            baselineCount: filteredBaseline.count,
            deletedBaselineCount: deletedBaselineCount,
            modifiedBaselineCount: modifiedBaselineCount,
            newPathCount: newPathCount
        )
    }
}

private struct MassDeletionSignal {
    let role: PlanRole
    let baselineCount: Int
    let deletedBaselineCount: Int
    let modifiedBaselineCount: Int
    let newPathCount: Int

    var retainedBaselineCount: Int {
        max(0, baselineCount - deletedBaselineCount)
    }

    var estimatedCurrentCount: Int {
        max(0, retainedBaselineCount + newPathCount)
    }

    var isCompleteWipe: Bool {
        baselineCount > 0 && deletedBaselineCount == baselineCount && estimatedCurrentCount == 0
    }

    var isNearEmptyMassDeletion: Bool {
        guard baselineCount >= 64 else {
            return false
        }

        let minimumDeletedCount = max(32, Int(Double(baselineCount) * 0.9))
        let maximumRemainingCount = max(4, Int(ceil(Double(baselineCount) * 0.05)))
        let maximumChangedCount = max(8, Int(ceil(Double(baselineCount) * 0.05)))

        guard deletedBaselineCount >= minimumDeletedCount else {
            return false
        }
        guard estimatedCurrentCount <= maximumRemainingCount else {
            return false
        }
        guard modifiedBaselineCount <= maximumChangedCount else {
            return false
        }
        guard newPathCount <= maximumChangedCount else {
            return false
        }
        return true
    }

    var isRecoveryCandidate: Bool {
        isCompleteWipe || isNearEmptyMassDeletion
    }
}
