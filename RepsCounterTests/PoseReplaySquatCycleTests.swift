import CoreGraphics
import XCTest
@testable import RepsCounter

final class PoseReplaySquatCycleTests: XCTestCase {
    private enum Posture {
        case upright, mid, low, perspective, shallow, borderline, supportOnly

        var geometry: (hip: Double, knee: Double, forward: Double) {
            switch self {
            case .upright: return (0.80, 0.50, 0)
            case .mid: return (0.64, 0.47, 0.06)
            case .low: return (0.47, 0.48, 0.14)
            case .perspective: return (0.57, 0.50, 0.13)
            case .shallow: return (0.62, 0.49, 0.12)
            case .borderline: return (0.53, 0.52, 0.14)
            case .supportOnly: return (0.525, 0.44, 0.13)
            }
        }
    }

    private func frame(_ time: Double, _ left: Posture?, _ right: Posture?,
                       confidence: Float = 1, footShift: Double = 0, hipShift: Double = 0,
                       rotation: CGFloat = 90) -> PoseReplayEvent {
        var joints: [BodyJoint: JointPoint] = [:]
        for (side, posture, base) in [(BodyLeg.left, left, 0.3), (.right, right, 0.7)] {
            guard let posture else { continue }
            let g = posture.geometry
            let isLeft = side == .left
            joints[isLeft ? .leftHip : .rightHip] = JointPoint(
                location: CGPoint(x: base + (isLeft ? hipShift : 0), y: g.hip), confidence: confidence)
            joints[isLeft ? .leftKnee : .rightKnee] = JointPoint(
                location: CGPoint(x: base + g.forward, y: g.knee), confidence: 1)
            joints[isLeft ? .leftAnkle : .rightAnkle] = JointPoint(
                location: CGPoint(x: base + (isLeft ? footShift : 0), y: 0.2), confidence: 1)
        }
        let pose = BodyPose(joints: joints, aspectRatio: 1, rotationAngle: rotation)
        return .init(seconds: time, kind: .pose, pose: .init(from: pose))
    }

    private func session(_ events: [PoseReplayEvent]) -> PoseReplaySession {
        .init(schemaVersion: 1, events: events, annotations: [])
    }

    private var start: [PoseReplayEvent] {
        [frame(0, .upright, .upright), frame(0.1, .upright, .upright), frame(0.2, .mid, .mid)]
    }

    private var finish: [PoseReplayEvent] {
        [frame(0.85, .mid, .mid), frame(0.95, .upright, .upright), frame(1.06, .upright, .upright)]
    }

    private func run(_ events: [PoseReplayEvent]) -> [PoseReplaySquatCycle.Step] {
        var cycle = PoseReplaySquatCycle()
        return events.map { cycle.process($0) }
    }

    func testDistinctTimesCanConfirmOppositeLegsInsideOneCycle() throws {
        let events = start + [frame(0.31, .low, nil), frame(0.40, nil, .low), frame(0.58, .low, .low),
                              frame(0.72, .low, .low)] + finish
        XCTAssertEqual(try PoseReplaySquatCycle.replay(session(events)), [1.06])
        XCTAssertEqual(run(events).filter { $0.reason == .bilateralDepth }.count, 1)
        XCTAssertEqual(try PoseReplayBilateralRunner.replay(session(events)).unifiedCountedAtSeconds, [1.06])
    }

    func testRepeatedOrIsolatedFrameCannotSupplyBilateralDwell() {
        let deep = frame(0.4, .low, .low)
        for second in [deep, frame(0.42, .low, .low), frame(0.49, nil, nil)] {
            let result = run(start + [deep, second, frame(0.61, .mid, .mid), frame(0.73, .upright, .upright)] + finish)
            XCTAssertFalse(result.contains(where: \.counted))
            XCTAssertFalse(result.contains { $0.phase == .lowered })
        }
    }

    func testMissingSamplesPreserveOnlyFreshEvidenceOfOriginalLeg() {
        let prefix = start + [frame(0.30, .low, nil), frame(0.41, .low, nil)]
        let hidden = frame(0.51, .low, .low, confidence: 0.49)
        let restored = run(prefix + [hidden, frame(0.60, .low, nil), frame(0.71, .low, nil)] + finish)
        XCTAssertEqual(restored[5].reason, .missingJoints)
        XCTAssertEqual(restored.filter { $0.reason == .unilateralDepth }.count, 1)
        XCTAssertEqual(restored.filter(\.counted).count, 1)
        let missingBottom = run(prefix + [hidden, frame(0.62, .mid, .mid), frame(0.72, .mid, .mid)] + finish)
        XCTAssertFalse(missingBottom.contains(where: \.counted))
    }

    func testProlongedOcclusionResetAndGeometryBoundariesCancelCycle() {
        let confirmed = start + [frame(0.30, .low, .low), frame(0.41, .low, .low)]
        let interruptions: [[PoseReplayEvent]] = [
            [frame(0.50, nil, nil), frame(0.62, nil, nil), frame(0.72, nil, nil)],
            [frame(0.72, .low, .low)],
            [.init(seconds: 0.5, kind: .reset, pose: nil)],
            [frame(0.5, .low, .low, rotation: 0)]
        ]
        for interruption in interruptions {
            XCTAssertFalse(run(confirmed + interruption + finish).contains(where: \.counted))
        }
    }

    func testRepeatedStrictEvidenceRequiresCorroborationWhenOppositeLegIsVisible() {
        let supported = start + [0.30, 0.40, 0.50, 0.60, 0.71].map { frame($0, .low, .perspective) } + finish
        XCTAssertTrue(run(supported).contains { $0.reason == .sustainedDepth })
        XCTAssertEqual(run(supported).filter(\.counted).count, 1)
        let partial = start + [0.30, 0.40, 0.50, 0.60, 0.71].map { frame($0, .borderline, .shallow) } + finish
        XCTAssertFalse(run(partial).contains(where: \.counted))
        XCTAssertFalse(run(partial).contains { $0.phase == .lowered })
    }

    func testContradictionStepsAndTurnsYieldInsufficientData() {
        let cases: [(PoseReplayEvent, PoseReplaySquatCycle.Reason)] = [
            (frame(0.3, .low, .upright), .conflictingLegs),
            (frame(0.3, .low, .low, footShift: 0.2), .movingSupport),
            (frame(0.3, .low, .low, hipShift: 0.2), .movingSupport),
            (frame(0.3, .low, .low, confidence: 0.2, footShift: 0.2), .movingSupport)
        ]
        for (bad, reason) in cases {
            let result = run(start + [bad, frame(0.40, .low, .low), frame(0.5, .low, .low)] + finish)
            XCTAssertEqual(result[start.count].phase, .insufficientData)
            XCTAssertEqual(result[start.count].reason, reason)
            XCTAssertFalse(result.contains(where: \.counted))
        }
    }

    func testTwoFastCyclesAndInterruptedReturnCannotDoubleOrMerge() throws {
        let events = start + [frame(0.30, .low, .low), frame(0.38, .low, .low), frame(0.47, .upright, .upright)]
        let next = [frame(0.58, .mid, .mid), frame(0.68, .low, .low), frame(0.77, .low, .low)]
        let tail = [frame(0.87, .upright, .upright), frame(0.97, .upright, .upright), frame(1.07, .upright, .upright)]
        XCTAssertEqual(try PoseReplaySquatCycle.replay(session(events + [frame(0.55, .upright, .upright)] + next + tail)), [0.55, 0.97])
        let interrupted = run(events + next + tail)
        XCTAssertTrue(interrupted.contains { $0.reason == .renewedDescent })
        XCTAssertFalse(interrupted.contains(where: \.counted))
    }

    func testEveryPrefixIsCausalAndIndependentOfAnnotations() throws {
        let events = start + [frame(0.31, .low, .low), frame(0.43, .low, .low), frame(0.59, .low, .low),
                              frame(0.70, .low, .low)] + finish
        let expected = run(events)
        for n in 0...events.count {
            var replay = session(Array(events.prefix(n)))
            replay.annotations = [.init(startSeconds: 50, endSeconds: 1, isFullSquat: false)]
            var steps: [PoseReplaySquatCycle.Step] = []
            _ = try PoseReplaySquatCycle.replay(replay) { _, step in steps.append(step) }
            XCTAssertEqual(steps, Array(expected.prefix(n)))
        }
        var processed = 0
        XCTAssertThrowsError(try PoseReplaySquatCycle.replay(session(events + [frame(0.09, .low, .low)])) { _, _ in processed += 1 })
        XCTAssertEqual(processed, events.count)
    }

    func testLongBottomExpiresAndLingeringInStandingCannotEmitAgain() {
        var cycle = PoseReplaySquatCycle()
        for event in start { _ = cycle.process(event) }
        var expirations = 0
        for index in 3...300 {
            let event = frame(Double(index) / 10, .low, .low)
            let step = cycle.process(event)
            if step.reason == .expired { expirations += 1 }
            XCTAssertFalse(step.counted)
        }
        XCTAssertEqual(expirations, 1)
        for index in 301...1400 {
            XCTAssertFalse(cycle.process(frame(Double(index) / 10, .upright, .upright)).counted)
        }
    }

    func testSideReturningAfterStaleCalibrationCannotWitnessDepth() {
        var events = [frame(0, .upright, .upright), frame(0.1, .upright, .upright)]
        events += (2...12).map { frame(Double($0) / 10, .upright, nil) }
        events += [frame(1.30, .mid, .mid), frame(1.40, .shallow, .low), frame(1.50, .shallow, .low),
                   frame(1.60, .shallow, .low), frame(1.70, .mid, .mid), frame(1.80, .upright, .upright),
                   frame(1.90, .upright, .upright)]
        XCTAssertFalse(run(events).contains { $0.phase == .lowered || $0.counted })
    }

    func testUncalibratedVisibleSideCannotKeepHiddenMovementAlive() {
        var events = [frame(0, .upright, nil), frame(0.1, .upright, nil), frame(0.2, .mid, nil)]
        events += [0.30, 0.41, 0.52, 0.63].map { frame($0, .low, nil) }
        events += [0.73, 0.83, 0.94].map { frame($0, nil, .mid) }
        events += [frame(1.04, .upright, .upright), frame(1.14, .upright, .upright)]
        let steps = run(events)
        XCTAssertTrue(steps.contains { $0.phase == .lowered })
        XCTAssertTrue(steps.contains { $0.reason == .interrupted })
        XCTAssertFalse(steps.contains(where: \.counted))
    }

    func testWeakObservationAndSingleBilateralFrameCannotSupplyTwoWitnesses() {
        let events = start + [frame(0.30, .supportOnly, nil), frame(0.40, .low, .supportOnly),
                              frame(0.51, .mid, .mid), frame(0.61, .upright, .upright),
                              frame(0.71, .upright, .upright)]
        XCTAssertFalse(run(events).contains { $0.phase == .lowered || $0.counted })
    }

    func testSwappingTheOccludedSidePreservesTheCycle() throws {
        let left = start + [0.31, 0.41, 0.50, 0.62, 0.71].map { frame($0, .low, nil) } + finish
        let right = start + [0.31, 0.41, 0.50, 0.62, 0.71].map { frame($0, nil, .low) } + finish
        XCTAssertEqual(run(left), run(right))
        XCTAssertEqual(try PoseReplaySquatCycle.replay(session(left)), [1.06])
    }

    func testRecordingBeginningLoweredNeedsObservedStandingBeforeFirstCount() throws {
        var replay = PoseReplaySession(schemaVersion: 2, events: [], annotations: [], initialState: .init(
            phase: .lowered, pendingFrames: 2, selectedLeg: .left, smoothedAngle: 90))
        replay.events = [frame(0, .low, .low), frame(0.1, .low, .low), frame(0.2, .upright, .upright),
                         frame(0.3, .upright, .upright), frame(0.41, .mid, .mid), frame(0.52, .low, .low),
                         frame(0.63, .low, .low), frame(0.73, .low, .low)] + finish
        XCTAssertEqual(try PoseReplaySquatCycle.replay(replay), [1.06])
    }
}
