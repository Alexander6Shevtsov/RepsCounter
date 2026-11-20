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


#if DEBUG
enum BilateralGuardPolicy {
    case strict
    case calibratedProjection
}
#endif

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
    let rejectedLeftCandidates: Int
    let rejectedRightCandidates: Int
}
#endif

private struct BilateralLegTracker {
    let leg: BodyLeg
    private var analyzer = PoseAnalyzer()
    private var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
    private var lastValidTime: TimeInterval?
    private var loweredAt: TimeInterval?
    private var missingSampleCount = 0
    private var recentKneeAngles: [(timestamp: TimeInterval, angle: Double)] = []
    #if DEBUG
    private var standingHipAnkleHeight: Double?
    private var standingCalibrationFrames = 0
    private var recentDepthEvidence: [(timestamp: TimeInterval, descent: Double)] = []
    #endif
    private let maximumMissingDuration: TimeInterval = 0.22
    private let maximumEvidenceDuration: TimeInterval = 3.0
    private let kneeEvidenceWindow: TimeInterval = 0.55
    private let requiredContradictionFrames = 3
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
        recentKneeAngles.removeAll { timestamp - $0.timestamp > maximumEvidenceDuration }
        #if DEBUG
        recentDepthEvidence.removeAll { timestamp - $0.timestamp > maximumEvidenceDuration }
        #endif
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
            recentKneeAngles.removeAll()
        }
        if let measuredAngle = analysis.measuredAngle, !analysis.requiresMovementReset {
            recentKneeAngles.append((timestamp: timestamp, angle: measuredAngle))
            #if DEBUG
            updateProjectionEvidence(
                pose: selectedPose,
                measuredAngle: measuredAngle,
                heightRatio: analysis.hipKneeHeightRatio,
                at: timestamp
            )
            #endif
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

    func hasContradictoryKneeEvidence(for candidate: BilateralSquatCandidate) -> Bool {
        let windowStart = candidate.loweredAt - kneeEvidenceWindow
        let windowEnd = min(candidate.countedAt, candidate.loweredAt + kneeEvidenceWindow)
        let validAngles = recentKneeAngles.filter {
            $0.timestamp >= windowStart && $0.timestamp <= windowEnd
        }
        return validAngles.count >= requiredContradictionFrames
            && validAngles.allSatisfy { $0.angle > counter.loweredThreshold }
    }

    #if DEBUG
    func hasCalibratedDepthEvidence(for candidate: BilateralSquatCandidate) -> Bool {
        let windowStart = candidate.loweredAt - 0.55
        let windowEnd = min(candidate.countedAt, candidate.loweredAt + 0.55)
        let samples = recentDepthEvidence.filter {
            $0.timestamp >= windowStart && $0.timestamp <= windowEnd
        }
        return samples.count >= 3
            && (samples.map(\.descent).max() ?? 0) >= 0.44
    }

    func hasConsistentlyExtendedOppositeKnee(for candidate: BilateralSquatCandidate) -> Bool {
        let windowStart = candidate.loweredAt - 0.55
        let windowEnd = min(candidate.countedAt, candidate.loweredAt + 0.55)
        let samples = recentKneeAngles.filter {
            $0.timestamp >= windowStart && $0.timestamp <= windowEnd
        }
        return samples.count >= 3 && samples.allSatisfy { $0.angle >= 120 }
    }

    private mutating func updateProjectionEvidence(
        pose: BodyPose?,
        measuredAngle: Double,
        heightRatio: Double?,
        at timestamp: TimeInterval
    ) {
        let hipJoint: BodyJoint = leg == .left ? .leftHip : .rightHip
        let ankleJoint: BodyJoint = leg == .left ? .leftAnkle : .rightAnkle
        guard let hipPoint = pose?.joints[hipJoint],
              let anklePoint = pose?.joints[ankleJoint] else { return }
        let height = Double(hipPoint.location.y - anklePoint.location.y)
        guard height.isFinite, height > 0.05 else { return }

        if measuredAngle >= 160 {
            standingCalibrationFrames = min(3, standingCalibrationFrames + 1)
            standingHipAnkleHeight = standingHipAnkleHeight.map {
                0.92 * $0 + 0.08 * height
            } ?? height
        }
        guard standingCalibrationFrames >= 3,
              measuredAngle <= 105,
              let heightRatio, heightRatio <= 0.35,
              let standingHipAnkleHeight, standingHipAnkleHeight > 0.05 else {
            return
        }
        let descent = (standingHipAnkleHeight - height) / standingHipAnkleHeight
        if descent.isFinite {
            recentDepthEvidence.append((timestamp: timestamp, descent: descent))
        }
    }
    #endif

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
        recentKneeAngles.removeAll()
        #if DEBUG
        standingHipAnkleHeight = nil
        standingCalibrationFrames = 0
        recentDepthEvidence.removeAll()
        #endif
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

    #if DEBUG
    private var guardPolicy: BilateralGuardPolicy = .strict

    init(guardPolicy: BilateralGuardPolicy = .strict) {
        self.guardPolicy = guardPolicy
    }
    #endif

    let maximumCompletionDifference: TimeInterval = 0.75

    #if DEBUG
    private var rejectedLeftCandidates = 0
    private var rejectedRightCandidates = 0

    var telemetry: BilateralCounterTelemetry {
        BilateralCounterTelemetry(
            left: leftTracker.telemetry,
            right: rightTracker.telemetry,
            repetitions: repetitions,
            pendingCount: pendingMovements.count,
            mergedDuplicates: mergedDuplicates,
            rejectedLeftCandidates: rejectedLeftCandidates,
            rejectedRightCandidates: rejectedRightCandidates
        )
    }
    #endif

    mutating func process(_ pose: BodyPose?, at timestamp: TimeInterval) -> Int {
        guard timestamp.isFinite, timestamp >= 0 else { return 0 }
        let leftCandidate = leftTracker.process(pose, at: timestamp)
        let rightCandidate = rightTracker.process(pose, at: timestamp)
        if let leftCandidate {
            if shouldReject(
                leftCandidate, candidateTracker: leftTracker, oppositeTracker: rightTracker
            ) {
                #if DEBUG
                rejectedLeftCandidates += 1
                #endif
            } else {
                append(leftCandidate)
            }
        }
        if let rightCandidate {
            if shouldReject(
                rightCandidate, candidateTracker: rightTracker, oppositeTracker: leftTracker
            ) {
                #if DEBUG
                rejectedRightCandidates += 1
                #endif
            } else {
                append(rightCandidate)
            }
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
        rejectedLeftCandidates = 0
        rejectedRightCandidates = 0
        #endif
        repetitions = 0
        mergedDuplicates = 0
        pendingMovements.removeAll()
    }

    private func shouldReject(
        _ candidate: BilateralSquatCandidate,
        candidateTracker: BilateralLegTracker,
        oppositeTracker: BilateralLegTracker
    ) -> Bool {
        guard oppositeTracker.hasContradictoryKneeEvidence(for: candidate) else {
            return false
        }
        #if DEBUG
        if guardPolicy == .calibratedProjection
            && candidateTracker.hasCalibratedDepthEvidence(for: candidate)
            && oppositeTracker.hasConsistentlyExtendedOppositeKnee(for: candidate) {
            return false
        }
        #endif
        return true
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
