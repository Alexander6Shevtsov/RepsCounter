import CoreGraphics
import Foundation

#if DEBUG
enum PoseReplayJoint: String, Codable, CaseIterable {
    case leftHip
    case leftKnee
    case leftAnkle
    case rightHip
    case rightKnee
    case rightAnkle

    var bodyJoint: BodyJoint {
        switch self {
        case .leftHip: return .leftHip
        case .leftKnee: return .leftKnee
        case .leftAnkle: return .leftAnkle
        case .rightHip: return .rightHip
        case .rightKnee: return .rightKnee
        case .rightAnkle: return .rightAnkle
        }
    }
}

struct PoseReplayPoint: Codable {
    let joint: PoseReplayJoint
    let horizontalPosition: Double
    let verticalPosition: Double
    let confidence: Double
}

struct PoseReplayPose: Codable {
    let aspectRatio: Double
    let rotationAngle: Double
    let points: [PoseReplayPoint]

    init(from pose: BodyPose) {
        aspectRatio = Double(pose.aspectRatio)
        rotationAngle = Double(pose.rotationAngle)
        points = PoseReplayJoint.allCases.compactMap { joint in
            guard let point = pose.joints[joint.bodyJoint],
                  point.location.x.isFinite, point.location.y.isFinite,
                  point.confidence.isFinite, (0...1).contains(point.confidence) else {
                return nil
            }
            return PoseReplayPoint(
                joint: joint,
                horizontalPosition: Double(point.location.x),
                verticalPosition: Double(point.location.y),
                confidence: Double(point.confidence)
            )
        }
    }

    func restore() -> BodyPose {
        var joints: [BodyJoint: JointPoint] = [:]
        for point in points {
            joints[point.joint.bodyJoint] = JointPoint(
                location: CGPoint(x: point.horizontalPosition, y: point.verticalPosition),
                confidence: Float(point.confidence)
            )
        }
        return BodyPose(
            joints: joints,
            aspectRatio: CGFloat(aspectRatio),
            rotationAngle: CGFloat(rotationAngle)
        )
    }
}

enum PoseReplayEventKind: String, Codable {
    case pose
    case reset
}

struct PoseReplayEvent: Codable {
    let seconds: TimeInterval
    let kind: PoseReplayEventKind
    let pose: PoseReplayPose?
}

struct PoseReplayAnnotation: Codable {
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let isFullSquat: Bool
}

struct PoseReplayInitialState: Codable {
    let phase: SquatPhase
    let pendingFrames: Int
    let selectedLeg: BodyLeg?
    let smoothedAngle: Double?
}

struct PoseReplaySession: Codable {
    let schemaVersion: Int
    var events: [PoseReplayEvent]
    var annotations: [PoseReplayAnnotation]
    var initialState: PoseReplayInitialState?
}

struct PoseReplayDepthSample {
    let movementReset: Bool
    let invalidGeometry: Bool
    let phase: SquatPhase
    let counted: Bool
    let seconds: TimeInterval
    let selectedLeg: BodyLeg?
    let kneeAngle: Double?
    let signedHipKneeVerticalDistance: Double?
    let normalizedThighHeight: Double?
    let hipBelowKnee: Bool?
}

struct PoseReplayResult {
    let countedAtSeconds: [TimeInterval]
    let depthSamples: [PoseReplayDepthSample]
}

struct PoseReplayScore {
    let truePositives: Int
    let falsePositives: Int
    let falseNegatives: Int
}

enum PoseReplayError: Error {
    case invalidVersion
    case invalidInitialState
    case invalidTimeline
    case tooManyEvents
    case invalidGeometry
    case invalidAnnotations
}

struct PoseReplayRecorder {
    private(set) var isRecording = false
    private(set) var session = PoseReplaySession(schemaVersion: 1, events: [], annotations: [])
    private var startedAt: TimeInterval?
    let maximumEvents = 1200

    var eventCount: Int { session.events.count }

    mutating func start(at timestamp: TimeInterval, initialState: PoseReplayInitialState? = nil) -> Bool {
        guard timestamp.isFinite else { return false }
        session = PoseReplaySession(
            schemaVersion: initialState == nil ? 1 : 2,
            events: [],
            annotations: [],
            initialState: initialState
        )
        startedAt = timestamp
        isRecording = true
        return true
    }

    mutating func append(_ pose: BodyPose?, at timestamp: TimeInterval) {
        append(kind: .pose, pose: pose, at: timestamp)
    }

    mutating func markReset(at timestamp: TimeInterval) {
        append(kind: .reset, pose: nil, at: timestamp)
    }

    mutating func stop() {
        isRecording = false
    }

    func encodedSession() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(session)
    }

    private mutating func append(
        kind: PoseReplayEventKind,
        pose: BodyPose?,
        at timestamp: TimeInterval
    ) {
        guard isRecording, let startedAt, timestamp.isFinite,
              timestamp >= startedAt, session.events.count < maximumEvents else { return }
        session.events.append(
            PoseReplayEvent(
                seconds: timestamp - startedAt,
                kind: kind,
                pose: pose.map(PoseReplayPose.init(from:))
            )
        )
    }
}

enum PoseReplayRunner {
    static func replay(_ session: PoseReplaySession) throws -> PoseReplayResult {
        try validate(session)
        let analyzer = PoseAnalyzer(
            replayLeg: session.initialState?.selectedLeg,
            smoothedAngle: session.initialState?.smoothedAngle
        )
        var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
        if let state = session.initialState {
            guard (0...counter.requiredStableFrames).contains(state.pendingFrames),
                  state.smoothedAngle.map({ (0...180).contains($0) }) ?? true,
                  (state.selectedLeg == nil) == (state.smoothedAngle == nil),
                  state.selectedLeg != nil || (state.phase == .seekingStanding && state.pendingFrames == 0)
            else { throw PoseReplayError.invalidInitialState }
            counter.restoreMovement(phase: state.phase, pendingFrames: state.pendingFrames)
        }
        var lastValidTimestamp: TimeInterval?
        var countedAtSeconds: [TimeInterval] = []
        var depthSamples: [PoseReplayDepthSample] = []

        for event in session.events {
            if event.kind == .reset {
                analyzer.reset()
                counter.resetMovement()
                lastValidTimestamp = nil
                continue
            }
            if session.schemaVersion == 1, let lastValidTimestamp, event.seconds - lastValidTimestamp > 0.25 {
                analyzer.reset()
                counter.resetMovement()
            }
            let pose = event.pose?.restore()
            let analysis = analyzer.analyze(pose)
            if analysis.requiresMovementReset {
                counter.resetMovement()
            }
            let counted = counter.process(
                measuredAngle: analysis.measuredAngle,
                smoothedAngle: analysis.smoothedAngle,
                hipKneeHeightRatio: analysis.hipKneeHeightRatio
            )
            if counted {
                countedAtSeconds.append(event.seconds)
            }
            lastValidTimestamp = analysis.smoothedAngle == nil ? nil : event.seconds

            let verticalDistance = signedVerticalDistance(
                pose: pose,
                selectedLeg: analysis.selectedLeg
            )
            depthSamples.append(
                PoseReplayDepthSample(
                    movementReset: analysis.requiresMovementReset,
                    invalidGeometry: analysis.leftMeasurement.issue == .invalidGeometry
                        || analysis.rightMeasurement.issue == .invalidGeometry,
                    phase: counter.phase,
                    counted: counted,
                    seconds: event.seconds,
                    selectedLeg: analysis.selectedLeg,
                    kneeAngle: analysis.measuredAngle,
                    signedHipKneeVerticalDistance: verticalDistance,
                    normalizedThighHeight: analysis.hipKneeHeightRatio,
                    hipBelowKnee: verticalDistance.map { $0 <= 0 }
                )
            )
        }
        return PoseReplayResult(
            countedAtSeconds: countedAtSeconds,
            depthSamples: depthSamples
        )
    }

    static func score(
        _ result: PoseReplayResult,
        against annotations: [PoseReplayAnnotation]
    ) throws -> PoseReplayScore {
        guard !annotations.isEmpty else { throw PoseReplayError.invalidAnnotations }
        try validateAnnotations(annotations)
        var truePositives = 0
        var falsePositives = 0
        var falseNegatives = 0
        var matchedCounts = 0

        for annotation in annotations {
            let counted = result.countedAtSeconds.filter {
                $0 >= annotation.startSeconds && $0 < annotation.endSeconds
            }.count
            matchedCounts += counted
            if annotation.isFullSquat {
                if counted > 0 {
                    truePositives += 1
                    falsePositives += counted - 1
                } else {
                    falseNegatives += 1
                }
            } else {
                falsePositives += counted
            }
        }
        falsePositives += result.countedAtSeconds.count - matchedCounts
        return PoseReplayScore(
            truePositives: truePositives,
            falsePositives: falsePositives,
            falseNegatives: falseNegatives
        )
    }

    private static func signedVerticalDistance(
        pose: BodyPose?,
        selectedLeg: BodyLeg?
    ) -> Double? {
        guard let pose, let selectedLeg else { return nil }
        let hipJoint: BodyJoint = selectedLeg == .left ? .leftHip : .rightHip
        let kneeJoint: BodyJoint = selectedLeg == .left ? .leftKnee : .rightKnee
        guard let hipPoint = pose.joints[hipJoint],
              let kneePoint = pose.joints[kneeJoint],
              hipPoint.confidence.isFinite, kneePoint.confidence.isFinite,
              hipPoint.confidence >= 0.5, kneePoint.confidence >= 0.5 else { return nil }
        let difference = Double(hipPoint.location.y - kneePoint.location.y)
        return difference.isFinite ? difference : nil
    }

    private static func validate(_ session: PoseReplaySession) throws {
        guard (1...2).contains(session.schemaVersion) else { throw PoseReplayError.invalidVersion }
        guard (session.schemaVersion == 2) == (session.initialState != nil) else {
            throw PoseReplayError.invalidInitialState
        }
        guard session.events.count <= 1200 else { throw PoseReplayError.tooManyEvents }
        try validateAnnotations(session.annotations)
        var previousTimestamp = 0.0
        for event in session.events {
            guard event.seconds.isFinite, event.seconds >= previousTimestamp else {
                throw PoseReplayError.invalidTimeline
            }
            previousTimestamp = event.seconds
            if event.kind == .reset {
                guard event.pose == nil else { throw PoseReplayError.invalidGeometry }
                continue
            }
            guard let pose = event.pose else { continue }
            guard pose.aspectRatio.isFinite, pose.aspectRatio > 0,
                  pose.rotationAngle.isFinite, pose.points.count <= 6 else {
                throw PoseReplayError.invalidGeometry
            }
            var joints = Set<PoseReplayJoint>()
            for point in pose.points {
                guard joints.insert(point.joint).inserted,
                      point.horizontalPosition.isFinite,
                      point.verticalPosition.isFinite,
                      point.confidence.isFinite,
                      (0...1).contains(point.confidence) else {
                    throw PoseReplayError.invalidGeometry
                }
            }
        }
    }

    private static func validateAnnotations(
        _ annotations: [PoseReplayAnnotation]
    ) throws {
        var priorEnd = 0.0
        for annotation in annotations {
            guard annotation.startSeconds.isFinite,
                  annotation.endSeconds.isFinite,
                  annotation.startSeconds >= priorEnd,
                  annotation.endSeconds > annotation.startSeconds else {
                throw PoseReplayError.invalidAnnotations
            }
            priorEnd = annotation.endSeconds
        }
    }
}
struct PoseReplayLegCount {
    let leg: BodyLeg
    let countedAtSeconds: TimeInterval
    let loweredAtSeconds: TimeInterval
}

struct PoseReplayBilateralEvent {
    let countedAtSeconds: TimeInterval
    let loweredAtSeconds: TimeInterval
    let contributingLegs: [BodyLeg]
}

struct PoseReplayBilateralResult {
    let baselineCountedAtSeconds: [TimeInterval]
    let leftCountedAtSeconds: [TimeInterval]
    let rightCountedAtSeconds: [TimeInterval]
    let combinedEvents: [PoseReplayBilateralEvent]
    let mergedDuplicateEvents: Int

    var countedAtSeconds: [TimeInterval] {
        combinedEvents.map(\.countedAtSeconds)
    }
}

private struct PoseReplayIndependentLeg {
    let leg: BodyLeg
    private var analyzer = PoseAnalyzer()
    private var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
    private var lastValidTimestamp: TimeInterval?
    private var loweredAtSeconds: TimeInterval?

    init(leg: BodyLeg) {
        self.leg = leg
    }

    mutating func process(_ event: PoseReplayEvent) -> PoseReplayLegCount? {
        guard event.kind == .pose else {
            resetMovement()
            return nil
        }

        if let lastValidTimestamp,
           event.seconds - lastValidTimestamp > 0.25 {
            resetMovement()
        }

        let restrictedPose = restrictToLeg(event.pose?.restore())
        let analysis = analyzer.analyze(restrictedPose)
        if analysis.requiresMovementReset {
            counter.resetMovement()
            loweredAtSeconds = nil
        }

        let previousPhase = counter.phase
        let counted = counter.process(
            measuredAngle: analysis.measuredAngle,
            smoothedAngle: analysis.smoothedAngle,
            hipKneeHeightRatio: analysis.hipKneeHeightRatio
        )
        lastValidTimestamp = analysis.smoothedAngle == nil
            ? nil : event.seconds

        if previousPhase != .lowered, counter.phase == .lowered {
            loweredAtSeconds = event.seconds
        }

        if counted {
            let loweredAt = loweredAtSeconds ?? event.seconds
            loweredAtSeconds = nil
            return PoseReplayLegCount(
                leg: leg,
                countedAtSeconds: event.seconds,
                loweredAtSeconds: loweredAt
            )
        }

        if previousPhase == .lowered, counter.phase != .lowered {
            loweredAtSeconds = nil
        }
        return nil
    }

    private mutating func resetMovement() {
        analyzer.reset()
        counter.resetMovement()
        lastValidTimestamp = nil
        loweredAtSeconds = nil
    }

    private func restrictToLeg(_ pose: BodyPose?) -> BodyPose? {
        guard let pose else { return nil }
        let hipJoint: BodyJoint
        let kneeJoint: BodyJoint
        let ankleJoint: BodyJoint
        switch leg {
        case .left:
            hipJoint = .leftHip
            kneeJoint = .leftKnee
            ankleJoint = .leftAnkle
        case .right:
            hipJoint = .rightHip
            kneeJoint = .rightKnee
            ankleJoint = .rightAnkle
        }

        var selectedJoints: [BodyJoint: JointPoint] = [:]
        for joint in [hipJoint, kneeJoint, ankleJoint] {
            if let point = pose.joints[joint] {
                selectedJoints[joint] = point
            }
        }
        return BodyPose(
            joints: selectedJoints,
            aspectRatio: pose.aspectRatio,
            rotationAngle: pose.rotationAngle
        )
    }
}

enum PoseReplayBilateralRunner {
    static func replay(_ session: PoseReplaySession) throws -> PoseReplayBilateralResult {
        let baseline = try PoseReplayRunner.replay(session)
        var leftTracker = PoseReplayIndependentLeg(leg: .left)
        var rightTracker = PoseReplayIndependentLeg(leg: .right)
        var candidates: [PoseReplayLegCount] = []

        for event in session.events {
            if let candidate = leftTracker.process(event) {
                candidates.append(candidate)
            }
            if let candidate = rightTracker.process(event) {
                candidates.append(candidate)
            }
        }

        let chronologicalCandidates = candidates.sorted {
            $0.countedAtSeconds < $1.countedAtSeconds
        }
        let combined = mergeMatchingMovements(chronologicalCandidates)
        return PoseReplayBilateralResult(
            baselineCountedAtSeconds: baseline.countedAtSeconds,
            leftCountedAtSeconds: chronologicalCandidates.compactMap {
                $0.leg == .left ? $0.countedAtSeconds : nil
            },
            rightCountedAtSeconds: chronologicalCandidates.compactMap {
                $0.leg == .right ? $0.countedAtSeconds : nil
            },
            combinedEvents: combined,
            mergedDuplicateEvents: candidates.count - combined.count
        )
    }

    static func mergeMatchingMovements(
        _ candidates: [PoseReplayLegCount]
    ) -> [PoseReplayBilateralEvent] {
        let maximumCompletionDifference = 0.75
        var combined: [PoseReplayBilateralEvent] = []

        for candidate in candidates {
            if let previous = combined.last,
               let lastIndex = combined.indices.last,
               !previous.contributingLegs.contains(candidate.leg),
               candidate.countedAtSeconds - previous.countedAtSeconds <= maximumCompletionDifference,
               candidate.loweredAtSeconds < previous.countedAtSeconds,
               candidate.countedAtSeconds > previous.loweredAtSeconds {
                combined[lastIndex] = PoseReplayBilateralEvent(
                    countedAtSeconds: previous.countedAtSeconds,
                    loweredAtSeconds: min(previous.loweredAtSeconds, candidate.loweredAtSeconds),
                    contributingLegs: previous.contributingLegs + [candidate.leg]
                )
            } else {
                combined.append(
                    PoseReplayBilateralEvent(
                        countedAtSeconds: candidate.countedAtSeconds,
                        loweredAtSeconds: candidate.loweredAtSeconds,
                        contributingLegs: [candidate.leg]
                    )
                )
            }
        }
        return combined
    }
}


struct PoseReplayDepthAttemptComparison {
    let isFullSquat: Bool
    let kneeOnly: Bool
    let legacyProjected: Bool
    let hipCenterBelowKnee: Bool
}

enum PoseReplayDepthGate: CaseIterable {
    case kneeOnly
    case legacyProjected
    case hipCenterBelowKnee
}

struct PoseReplayDepthGateScore {
    let fullSatisfied: Int
    let fullMissed: Int
    let partialAccepted: Int
    let partialRejected: Int
}

struct PoseReplayDepthAuditReport {
    let attempts: [PoseReplayDepthAttemptComparison]

    func score(for gate: PoseReplayDepthGate) -> PoseReplayDepthGateScore {
        var fullSatisfied = 0
        var fullMissed = 0
        var partialAccepted = 0
        var partialRejected = 0

        for attempt in attempts {
            let satisfied: Bool
            switch gate {
            case .kneeOnly: satisfied = attempt.kneeOnly
            case .legacyProjected: satisfied = attempt.legacyProjected
            case .hipCenterBelowKnee: satisfied = attempt.hipCenterBelowKnee
            }
            if attempt.isFullSquat {
                if satisfied { fullSatisfied += 1 }
                else { fullMissed += 1 }
            } else {
                if satisfied { partialAccepted += 1 }
                else { partialRejected += 1 }
            }
        }

        return PoseReplayDepthGateScore(
            fullSatisfied: fullSatisfied,
            fullMissed: fullMissed,
            partialAccepted: partialAccepted,
            partialRejected: partialRejected
        )
    }
}

enum PoseReplayDepthAudit {
    struct KneeObservation {
        let minimumConfidence: Double
        let ankle: CGPoint
        let hipX: Double
        let hipAnkleHeight: Double
        let kneeAngle: Double
        let signedHipKneeHeight: Double
        let normalizedThighHeight: Double
    }

    static func evaluate(_ session: PoseReplaySession) throws -> PoseReplayDepthAuditReport {
        guard !session.annotations.isEmpty else { throw PoseReplayError.invalidAnnotations }
        _ = try PoseReplayRunner.replay(session)
        let comparisons = session.annotations.map { annotation in
            compare(annotation: annotation, events: session.events)
        }
        return PoseReplayDepthAuditReport(attempts: comparisons)
    }

    private static func compare(
        annotation: PoseReplayAnnotation,
        events: [PoseReplayEvent]
    ) -> PoseReplayDepthAttemptComparison {
        var consecutiveFrames = [Int](repeating: 0, count: 6)
        var gateSatisfied = [Bool](repeating: false, count: 3)
        var previousTimestamp: TimeInterval?

        for event in events where event.seconds >= annotation.startSeconds
            && event.seconds < annotation.endSeconds {
            if event.kind == .reset
                || (previousTimestamp.map { event.seconds - $0 > 0.25 } ?? false) {
                consecutiveFrames = [Int](repeating: 0, count: 6)
            }
            previousTimestamp = event.seconds

            for (sideIndex, side) in [BodyLeg.left, .right].enumerated() {
                let observation = observe(event.pose, side: side)
                for (gateIndex, gate) in PoseReplayDepthGate.allCases.enumerated() {
                    let satisfied = observation.map { measurement in
                        passes(measurement, gate: gate)
                    } ?? false
                    let index = sideIndex * 3 + gateIndex
                    consecutiveFrames[index] = satisfied ? consecutiveFrames[index] + 1 : 0
                    if consecutiveFrames[index] >= 3 {
                        gateSatisfied[gateIndex] = true
                    }
                }
            }
        }

        return PoseReplayDepthAttemptComparison(
            isFullSquat: annotation.isFullSquat,
            kneeOnly: gateSatisfied[0],
            legacyProjected: gateSatisfied[1],
            hipCenterBelowKnee: gateSatisfied[2]
        )
    }

    private static func passes(_ measurement: KneeObservation, gate: PoseReplayDepthGate) -> Bool {
        guard measurement.kneeAngle <= 105 else { return false }
        switch gate {
        case .kneeOnly: return true
        case .legacyProjected: return measurement.normalizedThighHeight <= 0.35
        case .hipCenterBelowKnee: return measurement.signedHipKneeHeight <= 0
        }
    }

    static func observe(_ pose: PoseReplayPose?, side: BodyLeg) -> KneeObservation? {
        guard let pose, pose.aspectRatio.isFinite, pose.aspectRatio > 0 else { return nil }
        let hipJoint: PoseReplayJoint = side == .left ? .leftHip : .rightHip
        let kneeJoint: PoseReplayJoint = side == .left ? .leftKnee : .rightKnee
        let ankleJoint: PoseReplayJoint = side == .left ? .leftAnkle : .rightAnkle
        guard let hipPoint = pose.points.first(where: { $0.joint == hipJoint }),
              let kneePoint = pose.points.first(where: { $0.joint == kneeJoint }),
              let anklePoint = pose.points.first(where: { $0.joint == ankleJoint }),
              [hipPoint, kneePoint, anklePoint].allSatisfy({
                  $0.confidence.isFinite && (0.5...1).contains($0.confidence)
                      && $0.horizontalPosition.isFinite && $0.verticalPosition.isFinite
              }) else { return nil }

        let aspectRatio = CGFloat(pose.aspectRatio)
        let measuredAngle = JointAngleCalculator.angle(
            first: CGPoint(
                x: CGFloat(hipPoint.horizontalPosition) * aspectRatio,
                y: CGFloat(hipPoint.verticalPosition)
            ),
            vertex: CGPoint(
                x: CGFloat(kneePoint.horizontalPosition) * aspectRatio,
                y: CGFloat(kneePoint.verticalPosition)
            ),
            third: CGPoint(
                x: CGFloat(anklePoint.horizontalPosition) * aspectRatio,
                y: CGFloat(anklePoint.verticalPosition)
            )
        )
        guard let measuredAngle, measuredAngle.isFinite else { return nil }

        let horizontalDifference =
            (hipPoint.horizontalPosition - kneePoint.horizontalPosition) * pose.aspectRatio
        let verticalDifference = hipPoint.verticalPosition - kneePoint.verticalPosition
        let projectedThighLength = hypot(horizontalDifference, verticalDifference)
        guard projectedThighLength.isFinite, projectedThighLength > 0.000_001 else {
            return nil
        }

        return KneeObservation(
            minimumConfidence: min(hipPoint.confidence, kneePoint.confidence, anklePoint.confidence),
            ankle: CGPoint(x: anklePoint.horizontalPosition * pose.aspectRatio, y: anklePoint.verticalPosition),
            hipX: hipPoint.horizontalPosition * pose.aspectRatio,
            hipAnkleHeight: hipPoint.verticalPosition - anklePoint.verticalPosition,
            kneeAngle: measuredAngle,
            signedHipKneeHeight: verticalDifference,
            normalizedThighHeight: verticalDifference / projectedThighLength
        )
    }
}


struct PoseReplayAdaptiveDepthResult {
    let countedAtSeconds: [TimeInterval]
    let assistedDepthFrames: Int
    let heldLegFrames: Int
}

private final class PoseReplayGraceAnalyzer {
    private let analyzer = PoseAnalyzer()
    private var selectedLeg: BodyLeg?
    private var lastReliableTimestamp: TimeInterval?
    private(set) var heldFrames = 0

    private let maximumTransientLoss: TimeInterval = 0.23

    func analyze(
        _ pose: BodyPose?,
        at timestamp: TimeInterval
    ) -> (analysis: PoseAnalysis?, expired: Bool) {
        if let selectedLeg {
            let probe = PoseAnalyzer().analyze(pose)
            let measurement = selectedLeg == .left
                ? probe.leftMeasurement : probe.rightMeasurement
            if !measurement.isReliable {
                if let lastReliableTimestamp,
                   timestamp - lastReliableTimestamp <= maximumTransientLoss {
                    heldFrames += 1
                    return (nil, false)
                }
                reset()
                let analysis = analyzer.analyze(pose)
                self.selectedLeg = analysis.selectedLeg
                lastReliableTimestamp = analysis.selectedLeg == nil ? nil : timestamp
                return (analysis, true)
            }
        }

        let analysis = analyzer.analyze(pose)
        selectedLeg = analysis.selectedLeg
        lastReliableTimestamp = analysis.selectedLeg == nil ? nil : timestamp
        return (analysis, false)
    }

    func reset() {
        analyzer.reset()
        selectedLeg = nil
        lastReliableTimestamp = nil
    }
}

enum PoseReplayAdaptiveDepthAudit {
    private struct LegSample {
        let kneeAngle: Double
        let hipAnkleHeight: Double
    }

    private static let maximumAssistedRatio = 0.45
    private static let minimumHipDescent = 0.34
    private static let requiredBilateralFrames = 3

    static func replay(_ session: PoseReplaySession) throws -> PoseReplayAdaptiveDepthResult {
        try replay(session, preserveTransientLeg: false)
    }

    static func replayWithGrace(
        _ session: PoseReplaySession
    ) throws -> PoseReplayAdaptiveDepthResult {
        try replay(session, preserveTransientLeg: true)
    }

    private static func replay(
        _ session: PoseReplaySession,
        preserveTransientLeg: Bool
    ) throws -> PoseReplayAdaptiveDepthResult {
        _ = try PoseReplayRunner.replay(session)
        let analyzer = PoseAnalyzer()
        let graceAnalyzer = PoseReplayGraceAnalyzer()
        var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
        var leftStandingHeight: Double?
        var rightStandingHeight: Double?
        var lastValidTimestamp: TimeInterval?
        var consecutiveBilateralFrames = 0
        var assistedDepthFrames = 0
        var countedAtSeconds: [TimeInterval] = []

        for event in session.events {
            if event.kind == .reset {
                analyzer.reset()
                graceAnalyzer.reset()
                counter.resetMovement()
                leftStandingHeight = nil
                rightStandingHeight = nil
                lastValidTimestamp = nil
                consecutiveBilateralFrames = 0
                continue
            }

            if let lastValidTimestamp, event.seconds - lastValidTimestamp > 0.25 {
                analyzer.reset()
                graceAnalyzer.reset()
                counter.resetMovement()
                leftStandingHeight = nil
                rightStandingHeight = nil
                consecutiveBilateralFrames = 0
            }

            let pose = event.pose?.restore()
            let analysis: PoseAnalysis
            var expiredGrace = false
            if preserveTransientLeg {
                let observation = graceAnalyzer.analyze(pose, at: event.seconds)
                guard let reliableAnalysis = observation.analysis else {
                    consecutiveBilateralFrames = 0
                    continue
                }
                analysis = reliableAnalysis
                expiredGrace = observation.expired
            } else {
                analysis = analyzer.analyze(pose)
            }
            if analysis.requiresMovementReset || expiredGrace {
                counter.resetMovement()
                consecutiveBilateralFrames = 0
            }

            let leftSample = sample(
                pose, bodyLeg: .left, measurement: analysis.leftMeasurement
            )
            let rightSample = sample(
                pose, bodyLeg: .right, measurement: analysis.rightMeasurement
            )
            leftStandingHeight = updatedStandingHeight(
                leftStandingHeight, sample: leftSample
            )
            rightStandingHeight = updatedStandingHeight(
                rightStandingHeight, sample: rightSample
            )

            let bilateralSupport: Bool
            if analysis.selectedLeg != nil,
               let leftSample, let rightSample,
               let leftDescent = descent(leftSample, standingHeight: leftStandingHeight),
               let rightDescent = descent(rightSample, standingHeight: rightStandingHeight) {
                bilateralSupport = leftSample.kneeAngle <= 105
                    && rightSample.kneeAngle <= 105
                    && leftDescent >= minimumHipDescent
                    && rightDescent >= minimumHipDescent
            } else {
                bilateralSupport = false
            }
            consecutiveBilateralFrames = bilateralSupport
                ? consecutiveBilateralFrames + 1 : 0

            let existingRatio = analysis.hipKneeHeightRatio
            let assistedDepth = existingRatio.map { ratio in
                ratio > 0.35
                    && ratio <= maximumAssistedRatio
                    && consecutiveBilateralFrames >= requiredBilateralFrames
            } ?? false
            if assistedDepth {
                assistedDepthFrames += 1
            }
            let effectiveRatio = assistedDepth ? 0.35 : existingRatio
            if counter.process(
                measuredAngle: analysis.measuredAngle,
                smoothedAngle: analysis.smoothedAngle,
                hipKneeHeightRatio: effectiveRatio
            ) {
                countedAtSeconds.append(event.seconds)
            }
            lastValidTimestamp = analysis.smoothedAngle == nil ? nil : event.seconds
        }

        return PoseReplayAdaptiveDepthResult(
            countedAtSeconds: countedAtSeconds,
            assistedDepthFrames: assistedDepthFrames,
            heldLegFrames: preserveTransientLeg ? graceAnalyzer.heldFrames : 0
        )
    }

    private static func sample(
        _ pose: BodyPose?,
        bodyLeg: BodyLeg,
        measurement: LegMeasurement
    ) -> LegSample? {
        guard measurement.isReliable, let kneeAngle = measurement.angle,
              let pose else { return nil }
        let hipJoint: BodyJoint = bodyLeg == .left ? .leftHip : .rightHip
        let ankleJoint: BodyJoint = bodyLeg == .left ? .leftAnkle : .rightAnkle
        guard let hipPoint = pose.joints[hipJoint],
              let anklePoint = pose.joints[ankleJoint] else { return nil }
        let height = Double(hipPoint.location.y - anklePoint.location.y)
        guard height.isFinite, height > 0.05 else { return nil }
        return LegSample(kneeAngle: kneeAngle, hipAnkleHeight: height)
    }

    private static func updatedStandingHeight(
        _ currentHeight: Double?,
        sample: LegSample?
    ) -> Double? {
        guard let sample, sample.kneeAngle >= 160 else { return currentHeight }
        return currentHeight.map {
            0.92 * $0 + 0.08 * sample.hipAnkleHeight
        } ?? sample.hipAnkleHeight
    }

    private static func descent(
        _ sample: LegSample,
        standingHeight: Double?
    ) -> Double? {
        guard let standingHeight, standingHeight > 0.05 else { return nil }
        return (standingHeight - sample.hipAnkleHeight) / standingHeight
    }
}


struct PoseReplayAsymmetricResult {
    let countedAtSeconds: [TimeInterval]
    let supplementalAtSeconds: [TimeInterval]
}

enum PoseReplayAsymmetricDepthAudit {
    private struct SideCandidate {
        let seconds: TimeInterval
        let hasAsymmetricSupport: Bool
    }

    private static let maximumTransientLoss: TimeInterval = 0.23
    private static let minimumHipDescent = 0.44
    private static let minimumOppositeAngle = 145.0
    private static let duplicateTolerance: TimeInterval = 0.75

    static func replay(_ session: PoseReplaySession) throws -> PoseReplayAsymmetricResult {
        let baseline = try PoseReplayAdaptiveDepthAudit.replayWithGrace(session)
        let extraCandidates = sideCandidates(in: session, bodyLeg: .left)
            + sideCandidates(in: session, bodyLeg: .right)
        let supported = extraCandidates
            .filter { $0.hasAsymmetricSupport }
            .map(\.seconds)
            .sorted()
        var countedAtSeconds = baseline.countedAtSeconds.sorted()
        var supplementalAtSeconds: [TimeInterval] = []

        for timestamp in supported {
            guard !countedAtSeconds.contains(where: {
                abs($0 - timestamp) <= duplicateTolerance
            }) else { continue }
            countedAtSeconds.append(timestamp)
            supplementalAtSeconds.append(timestamp)
        }
        countedAtSeconds.sort()
        return PoseReplayAsymmetricResult(
            countedAtSeconds: countedAtSeconds,
            supplementalAtSeconds: supplementalAtSeconds
        )
    }

    private static func sideCandidates(
        in session: PoseReplaySession,
        bodyLeg: BodyLeg
    ) -> [SideCandidate] {
        let hipJoint: BodyJoint = bodyLeg == .left ? .leftHip : .rightHip
        let ankleJoint: BodyJoint = bodyLeg == .left ? .leftAnkle : .rightAnkle
        var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
        var smoothedAngle: Double?
        var standingHeight: Double?
        var lastReliableTimestamp: TimeInterval?
        var hasAsymmetricSupport = false
        var candidates: [SideCandidate] = []

        for event in session.events {
            if event.kind == .reset {
                counter.resetMovement()
                smoothedAngle = nil
                standingHeight = nil
                lastReliableTimestamp = nil
                hasAsymmetricSupport = false
                continue
            }

            let pose = event.pose?.restore()
            let analysis = PoseAnalyzer().analyze(pose)
            let measurement = bodyLeg == .left
                ? analysis.leftMeasurement : analysis.rightMeasurement
            let opposite = bodyLeg == .left
                ? analysis.rightMeasurement : analysis.leftMeasurement
            guard measurement.isReliable,
                  let measuredAngle = measurement.angle,
                  let pose,
                  let hipPoint = pose.joints[hipJoint],
                  let anklePoint = pose.joints[ankleJoint] else {
                if let lastReliableTimestamp,
                   event.seconds - lastReliableTimestamp <= maximumTransientLoss {
                    continue
                }
                counter.resetMovement()
                smoothedAngle = nil
                standingHeight = nil
                lastReliableTimestamp = nil
                hasAsymmetricSupport = false
                continue
            }

            if let lastReliableTimestamp,
               event.seconds - lastReliableTimestamp > 0.25 {
                counter.resetMovement()
                smoothedAngle = nil
                standingHeight = nil
                hasAsymmetricSupport = false
            }

            smoothedAngle = smoothedAngle.map {
                0.35 * measuredAngle + 0.65 * $0
            } ?? measuredAngle
            let height = Double(hipPoint.location.y - anklePoint.location.y)
            guard height.isFinite, height > 0.05 else {
                counter.resetMovement()
                smoothedAngle = nil
                standingHeight = nil
                lastReliableTimestamp = nil
                hasAsymmetricSupport = false
                continue
            }

            if measuredAngle >= 160 {
                standingHeight = standingHeight.map {
                    0.92 * $0 + 0.08 * height
                } ?? height
            }
            let kneeJoint: BodyJoint = bodyLeg == .left ? .leftKnee : .rightKnee
            let hipKneeHeightRatio: Double?
            if let kneePoint = pose.joints[kneeJoint],
               pose.aspectRatio.isFinite, pose.aspectRatio > 0 {
                let horizontal = Double(hipPoint.location.x - kneePoint.location.x)
                    * Double(pose.aspectRatio)
                let vertical = Double(hipPoint.location.y - kneePoint.location.y)
                let projectedLength = hypot(horizontal, vertical)
                hipKneeHeightRatio = projectedLength > 0.000_001
                    ? vertical / projectedLength : nil
            } else {
                hipKneeHeightRatio = nil
            }
            let normalizedDescent = standingHeight.map {
                ($0 - height) / $0
            }
            let supported = measuredAngle <= 105
                && (hipKneeHeightRatio.map { $0 <= 0.35 } ?? false)
                && (normalizedDescent.map { $0 >= minimumHipDescent } ?? false)
                && opposite.isReliable
                && (opposite.angle.map { $0 >= minimumOppositeAngle } ?? false)
            if supported {
                hasAsymmetricSupport = true
            }

            let counted = counter.process(
                measuredAngle: measuredAngle,
                smoothedAngle: smoothedAngle,
                hipKneeHeightRatio: hipKneeHeightRatio
            )
            if counted {
                candidates.append(
                    SideCandidate(
                        seconds: event.seconds,
                        hasAsymmetricSupport: hasAsymmetricSupport
                    )
                )
                hasAsymmetricSupport = false
            }
            lastReliableTimestamp = event.seconds
        }
        return candidates
    }
}

#endif
