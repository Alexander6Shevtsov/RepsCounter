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

struct PoseReplaySession: Codable {
    let schemaVersion: Int
    var events: [PoseReplayEvent]
    var annotations: [PoseReplayAnnotation]
}

struct PoseReplayDepthSample {
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

    mutating func start(at timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite else { return false }
        session = PoseReplaySession(schemaVersion: 1, events: [], annotations: [])
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
        let analyzer = PoseAnalyzer()
        var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
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
            if let lastValidTimestamp, event.seconds - lastValidTimestamp > 0.25 {
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
        guard session.schemaVersion == 1 else { throw PoseReplayError.invalidVersion }
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
#endif
