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


enum BilateralTrackingResetReason: Equatable {
    case observationGap
    case missingJoint
    case lowConfidence
    case invalidGeometry
    case externalReset
}

#if DEBUG
enum BilateralTrackingEvent: Equatable {
    case waiting
    case tracking
    case briefLoss
    case reset(BilateralTrackingResetReason)
    case candidate
}

struct BilateralLegTelemetry {
    let phase: SquatPhase
    let decision: SquatDecision
    let measuredAngle: Double?
    let smoothedAngle: Double?
    let hipKneeHeightRatio: Double?
    let confidence: Float?
    let missedFrames: Int
    let event: BilateralTrackingEvent
    let lastReset: BilateralTrackingResetReason?
    let resetCount: Int
    let candidateCount: Int
}

struct BilateralCounterTelemetry {
    let left: BilateralLegTelemetry
    let right: BilateralLegTelemetry
    let repetitions: Int
    let pendingCount: Int
    let mergedDuplicates: Int
}
#endif

private struct BilateralLegTracker {
    let leg: BodyLeg
    private var analyzer = PoseAnalyzer()
    private var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
    private var lastValidTime: TimeInterval?
    private var loweredAt: TimeInterval?
    private var missingSampleCount = 0
    private let maximumMissingDuration: TimeInterval = 0.22
    #if DEBUG
    private var lastAnalysis: PoseAnalysis?
    private var latestConfidence: Float?
    private var latestEvent: BilateralTrackingEvent = .waiting
    private var latestReset: BilateralTrackingResetReason?
    private var resetCount = 0
    private var candidateCount = 0

    var telemetry: BilateralLegTelemetry {
        BilateralLegTelemetry(
            phase: counter.phase,
            decision: counter.decision,
            measuredAngle: lastAnalysis?.measuredAngle,
            smoothedAngle: lastAnalysis?.smoothedAngle,
            hipKneeHeightRatio: lastAnalysis?.hipKneeHeightRatio,
            confidence: latestConfidence,
            missedFrames: missingSampleCount,
            event: latestEvent,
            lastReset: latestReset,
            resetCount: resetCount,
            candidateCount: candidateCount
        )
    }
    #endif

    init(leg: BodyLeg) {
        self.leg = leg
    }

    mutating func process(_ pose: BodyPose?, at timestamp: TimeInterval) -> BilateralSquatCandidate? {
        if let lastValidTime, timestamp - lastValidTime > 0.25 {
            resetMovement(reason: .observationGap)
        }
        let selectedPose = onlySelectedLeg(in: pose)
        #if DEBUG
        latestConfidence = selectedPose?.joints.values.map(\.confidence).min()
        #endif
        guard hasReliableJoints(selectedPose) else {
            if isTemporaryLandmarkLoss(selectedPose),
               let lastValidTime,
               missingSampleCount == 0,
               timestamp >= lastValidTime,
               timestamp - lastValidTime <= maximumMissingDuration {
                missingSampleCount = 1
                #if DEBUG
                lastAnalysis = nil
                latestEvent = .briefLoss
                #endif
                return nil
            }
            let reason = invalidObservationReason(for: selectedPose)
            resetMovement(reason: reason)
            #if DEBUG
            latestConfidence = selectedPose?.joints.values.map(\.confidence).min()
            #endif
            return nil
        }
        if missingSampleCount > 0,
           let lastValidTime,
           timestamp - lastValidTime > maximumMissingDuration {
            resetMovement(reason: .observationGap)
        }
        missingSampleCount = 0
        let analysis = analyzer.analyze(selectedPose)
        #if DEBUG
        lastAnalysis = analysis
        latestEvent = .tracking
        #endif
        if analysis.requiresMovementReset {
            #if DEBUG
            if counter.phase != .seekingStanding {
                resetCount += 1
                latestReset = .invalidGeometry
            }
            latestEvent = .reset(.invalidGeometry)
            #endif
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
            #if DEBUG
            candidateCount += 1
            latestEvent = .candidate
            #endif
            let start = loweredAt ?? timestamp
            loweredAt = nil
            return BilateralSquatCandidate(leg: leg, loweredAt: start, countedAt: timestamp)
        }
        if previousPhase == .lowered, counter.phase != .lowered {
            loweredAt = nil
        }
        return nil
    }

    mutating func resetMovement(reason: BilateralTrackingResetReason = .externalReset) {
        #if DEBUG
        if counter.phase != .seekingStanding || lastValidTime != nil {
            resetCount += 1
            latestReset = reason
        }
        lastAnalysis = nil
        latestConfidence = nil
        latestEvent = .reset(reason)
        #endif
        analyzer.reset()
        counter.resetMovement()
        lastValidTime = nil
        loweredAt = nil
        missingSampleCount = 0
    }

    #if DEBUG
    mutating func clearTelemetry() {
        lastAnalysis = nil
        latestConfidence = nil
        latestEvent = .waiting
        latestReset = nil
        resetCount = 0
        candidateCount = 0
    }
    #endif

    private func invalidObservationReason(for pose: BodyPose?) -> BilateralTrackingResetReason {
        guard let pose, pose.joints.count == 3 else { return .missingJoint }
        if pose.joints.values.contains(where: { point in
            point.confidence.isFinite && point.confidence < 0.5
        }) {
            return .lowConfidence
        }
        return .invalidGeometry
    }

    private func hasReliableJoints(_ pose: BodyPose?) -> Bool {
        guard let pose,
              pose.aspectRatio.isFinite, pose.aspectRatio > 0,
              pose.joints.count == 3 else { return false }
        return pose.joints.values.allSatisfy { point in
            point.confidence.isFinite
                && point.confidence >= 0.5
                && point.confidence <= 1
                && point.location.x.isFinite
                && point.location.y.isFinite
        }
    }

    private func isTemporaryLandmarkLoss(_ pose: BodyPose?) -> Bool {
        guard let pose else { return true }
        guard pose.aspectRatio.isFinite, pose.aspectRatio > 0 else { return false }
        guard pose.joints.values.allSatisfy({ point in
            point.location.x.isFinite
                && point.location.y.isFinite
                && point.confidence.isFinite
                && point.confidence >= 0
                && point.confidence <= 1
        }) else { return false }
        return pose.joints.count < 3
            || pose.joints.values.contains { $0.confidence < 0.5 }
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

    #if DEBUG
    var telemetry: BilateralCounterTelemetry {
        BilateralCounterTelemetry(
            left: leftTracker.telemetry,
            right: rightTracker.telemetry,
            repetitions: repetitions,
            pendingCount: pendingMovements.count,
            mergedDuplicates: mergedDuplicates
        )
    }
    #endif

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
        #if DEBUG
        leftTracker.clearTelemetry()
        rightTracker.clearTelemetry()
        #endif
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
