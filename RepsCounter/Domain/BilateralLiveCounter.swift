import Foundation

struct BilateralSquatCandidate {
    let leg: BodyLeg
    let loweredAt: TimeInterval
    let countedAt: TimeInterval
}

struct BilateralCombinedMovement {
    let loweredAt: TimeInterval
    let countedAt: TimeInterval
    let lastCountedAt: TimeInterval
    let contributingLegs: [BodyLeg]
}

private struct BilateralLegTracker {
    let leg: BodyLeg
    private var analyzer = PoseAnalyzer()
    private var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
    private var lastValidTime: TimeInterval?
    private var loweredAt: TimeInterval?

    init(leg: BodyLeg) {
        self.leg = leg
    }

    mutating func process(_ pose: BodyPose?, at timestamp: TimeInterval) -> BilateralSquatCandidate? {
        if let lastValidTime, timestamp - lastValidTime > 0.25 {
            resetMovement()
        }
        let analysis = analyzer.analyze(onlySelectedLeg(in: pose))
        if analysis.requiresMovementReset {
            counter.resetMovement()
            loweredAt = nil
        }
        let previousPhase = counter.phase
        let counted = counter.process(
            measuredAngle: analysis.measuredAngle,
            smoothedAngle: analysis.smoothedAngle,
            hipKneeHeightRatio: analysis.hipKneeHeightRatio
        )
        lastValidTime = analysis.smoothedAngle == nil ? nil : timestamp
        if previousPhase != .lowered, counter.phase == .lowered {
            loweredAt = timestamp
        }
        if counted {
            let start = loweredAt ?? timestamp
            loweredAt = nil
            return BilateralSquatCandidate(leg: leg, loweredAt: start, countedAt: timestamp)
        }
        if previousPhase == .lowered, counter.phase != .lowered {
            loweredAt = nil
        }
        return nil
    }

    mutating func resetMovement() {
        analyzer.reset()
        counter.resetMovement()
        lastValidTime = nil
        loweredAt = nil
    }

    private func onlySelectedLeg(in pose: BodyPose?) -> BodyPose? {
        guard let pose else { return nil }
        let selectedJoints: [BodyJoint]
        switch leg {
        case .left: selectedJoints = [.leftHip, .leftKnee, .leftAnkle]
        case .right: selectedJoints = [.rightHip, .rightKnee, .rightAnkle]
        }
        var joints: [BodyJoint: JointPoint] = [:]
        for joint in selectedJoints {
            if let point = pose.joints[joint] { joints[joint] = point }
        }
        return BodyPose(
            joints: joints,
            aspectRatio: pose.aspectRatio,
            rotationAngle: pose.rotationAngle
        )
    }
}

struct BilateralLiveCounter {
    private var leftTracker = BilateralLegTracker(leg: .left)
    private var rightTracker = BilateralLegTracker(leg: .right)
    private(set) var repetitions = 0
    private(set) var mergedDuplicates = 0
    private(set) var pendingMovements: [BilateralCombinedMovement] = []

    let maximumCompletionDifference: TimeInterval = 0.75

    mutating func process(_ pose: BodyPose?, at timestamp: TimeInterval) -> Int {
        guard timestamp.isFinite, timestamp >= 0 else { return 0 }
        if let leftCandidate = leftTracker.process(pose, at: timestamp) {
            append(leftCandidate)
        }
        if let rightCandidate = rightTracker.process(pose, at: timestamp) {
            append(rightCandidate)
        }
        return flush(at: timestamp)
    }

    mutating func flush(at timestamp: TimeInterval) -> Int {
        guard timestamp.isFinite else { return 0 }
        var committed = 0
        while let first = pendingMovements.first,
              timestamp - first.lastCountedAt > maximumCompletionDifference {
            pendingMovements.removeFirst()
            repetitions += 1
            committed += 1
        }
        return committed
    }

    mutating func finishPending() -> Int {
        let committed = pendingMovements.count
        repetitions += committed
        pendingMovements.removeAll()
        return committed
    }

    mutating func resetMovement() {
        leftTracker.resetMovement()
        rightTracker.resetMovement()
    }

    mutating func reset() {
        leftTracker.resetMovement()
        rightTracker.resetMovement()
        repetitions = 0
        mergedDuplicates = 0
        pendingMovements.removeAll()
    }

    private mutating func append(_ candidate: BilateralSquatCandidate) {
        if let lastIndex = pendingMovements.indices.last {
            let previous = pendingMovements[lastIndex]
            let sameMovement = !previous.contributingLegs.contains(candidate.leg)
                && abs(candidate.countedAt - previous.countedAt) <= maximumCompletionDifference
                && candidate.loweredAt < previous.lastCountedAt
                && candidate.countedAt > previous.loweredAt
            if sameMovement {
                pendingMovements[lastIndex] = BilateralCombinedMovement(
                    loweredAt: min(previous.loweredAt, candidate.loweredAt),
                    countedAt: min(previous.countedAt, candidate.countedAt),
                    lastCountedAt: max(previous.lastCountedAt, candidate.countedAt),
                    contributingLegs: previous.contributingLegs + [candidate.leg]
                )
                mergedDuplicates += 1
                return
            }
        }
        pendingMovements.append(
            BilateralCombinedMovement(
                loweredAt: candidate.loweredAt,
                countedAt: candidate.countedAt,
                lastCountedAt: candidate.countedAt,
                contributingLegs: [candidate.leg]
            )
        )
    }
}
