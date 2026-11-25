import CoreGraphics
import XCTest
@testable import RepsCounter

final class PoseReplaySquatCycleTests: XCTestCase {
    private enum Posture {
        case upright, nearStanding, mid, low, perspective, shallow, borderline, supportOnly

        var geometry: (hip: Double, knee: Double, forward: Double) {
            switch self {
            case .upright: return (0.80, 0.50, 0)
            case .nearStanding: return (0.75, 0.50, 0.065)
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
                       rotation: CGFloat = 90, shiftedSide: BodyLeg = .left,
                       unreliableJoint: BodyJoint? = nil) -> PoseReplayEvent {
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
                location: CGPoint(x: base + (side == shiftedSide ? footShift : 0), y: 0.2), confidence: 1)
        }
        if let unreliableJoint, let point = joints[unreliableJoint] {
            joints[unreliableJoint] = JointPoint(location: point.location, confidence: 0.49)
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

    private var confirmedBottom: [PoseReplayEvent] {
        start + [frame(0.30, .low, .low), frame(0.40, .low, .low)]
    }

    private var reacquiredAscent: [PoseReplayEvent] {
        confirmedBottom + [frame(0.50, .shallow, nil), frame(0.60, .mid, .perspective)]
    }

    func testReappearingLegDuringContinuousAscentRequiresBilateralStanding() throws {
        let events = reacquiredAscent + [frame(0.70, .upright, .mid), frame(0.80, .upright, .nearStanding),
                                         frame(0.90, .upright, .upright), frame(1.00, .upright, .upright)]
        let steps = run(events)
        XCTAssertEqual(steps[5].phase, .returning)
        XCTAssertEqual(steps[6].reason, .reacquiredDuringAscent)
        XCTAssertEqual(try PoseReplaySquatCycle.replay(session(events)), [1.00])
        for n in events.indices {
            XCTAssertEqual(run(Array(events.prefix(n + 1))), Array(steps.prefix(n + 1)))
        }
    }

    func testMirroringTheReappearingLegPreservesReturnDecisions() throws {
        let left = confirmedBottom + [frame(0.50, nil, .shallow), frame(0.60, .perspective, .mid),
                                      frame(0.70, .mid, .nearStanding)] + finish.dropFirst()
        let right = reacquiredAscent + [frame(0.70, .nearStanding, .mid)] + finish.dropFirst()
        XCTAssertEqual(run(left), run(right))
        XCTAssertEqual(try PoseReplaySquatCycle.replay(session(left)), [1.06])
    }

    func testSecondDescentOfContinuouslyVisibleLegCancelsReturn() {
        let prefix = confirmedBottom + [frame(0.50, .mid, nil)]
        for secondDescent in [frame(0.60, .low, nil), frame(0.60, .low, .perspective)] {
            let steps = run(prefix + [secondDescent, frame(0.70, .low, .low)] + finish)
            XCTAssertEqual(steps[prefix.count].reason, .renewedDescent)
            XCTAssertFalse(steps.contains(where: \.counted))
        }
    }

    func testSwappingVisibleLegWithoutOverlappingAscentCannotBridgeCycles() {
        let events = confirmedBottom + [frame(0.50, .shallow, nil), frame(0.60, nil, .perspective),
                                        frame(0.70, nil, .mid)] + finish
        let steps = run(events)
        XCTAssertEqual(steps[6].reason, .interrupted)
        XCTAssertFalse(steps.contains(where: \.counted))
    }

    func testReappearingLegNeedsAnExtendingWitnessAndCompatibleGeometry() {
        let prefix = confirmedBottom + [frame(0.50, .shallow, nil)]
        for overlap in [frame(0.60, .shallow, .perspective), frame(0.60, .mid, .low),
                        frame(0.60, .mid, .perspective, unreliableJoint: .leftKnee)] {
            let result = run(prefix + [overlap, frame(0.70, .nearStanding, .mid)] + finish)
            XCTAssertEqual(result[prefix.count].reason, .interrupted)
            XCTAssertFalse(result.contains(where: \.counted))
        }
    }

    func testIntermediateRisesWithoutExtensionCannotJoinSuccessiveBottoms() {
        let pulses = [frame(0.50, .mid, .mid), frame(0.60, .low, .low), frame(0.70, .mid, .mid),
                      frame(0.80, .low, .low)]
        let steps = run(confirmedBottom + pulses + finish)
        XCTAssertEqual(steps[6].reason, .renewedDescent)
        XCTAssertFalse(steps.contains(where: \.counted))
    }

    func testStepAfterDepthStillCancelsReacquiredAscent() {
        for side in [BodyLeg.left, .right] {
            let step = frame(0.70, .nearStanding, .mid, footShift: 0.2, shiftedSide: side)
            let result = run(reacquiredAscent + [step] + finish)
            XCTAssertEqual(result[reacquiredAscent.count].reason, .movingSupport)
            XCTAssertFalse(result.contains(where: \.counted))
        }
    }

    func testLosingEitherOrBothChainsDuringRevalidationCancelsReturn() {
        for hidden in [frame(0.70, nil, nil), frame(0.70, nil, .mid), frame(0.70, .nearStanding, nil),
                       suspectFoot(0.70, side: .right)] {
            let result = run(reacquiredAscent + [hidden] + finish)
            XCTAssertEqual(result[reacquiredAscent.count].phase, .insufficientData)
            XCTAssertFalse(result.contains(where: \.counted))
        }
    }

    func testStoppingShortOfBilateralExtensionCannotCompleteReacquiredReturn() {
        let events = reacquiredAscent + [frame(0.70, .upright, .nearStanding), frame(0.80, .upright, .nearStanding),
                                         frame(0.90, .upright, .nearStanding)]
        XCTAssertFalse(run(events).contains(where: \.counted))
    }

    func testRevalidationEndsWithItsOwnCycle() throws {
        let first = reacquiredAscent + [frame(0.70, .nearStanding, .mid)] + finish.dropFirst()
        let second = [frame(1.16, .mid, .mid), frame(1.26, .low, .low), frame(1.36, .low, .low),
                      frame(1.46, .mid, nil), frame(1.56, .upright, nil), frame(1.66, .upright, nil)]
        XCTAssertEqual(try PoseReplaySquatCycle.replay(session(first + second)), [1.06, 1.66])
    }

    private func suspectFoot(_ time: Double, side: BodyLeg = .left) -> PoseReplayEvent {
        frame(time, .low, .low, footShift: 0.2, shiftedSide: side,
              unreliableJoint: side == .left ? .leftHip : .rightHip)
    }

    func testDisplacedIsolatedAnkleWaitsForBothChainsAndBilateralStandingOnEitherSide() throws {
        for side in [BodyLeg.left, .right] {
            let oneLeg = side == .left ? frame(0.60, nil, .mid) : frame(0.60, .mid, nil)
            let events = confirmedBottom + [suspectFoot(0.50, side: side), oneLeg, frame(0.69, .mid, .mid),
                                            frame(0.80, .upright, .mid), frame(0.90, .upright, .upright),
                                            frame(1.0, .upright, .upright), frame(1.1, .upright, .upright)]
            let steps = run(events)
            XCTAssertEqual(steps[4].phase, .lowered)
            XCTAssertEqual(steps[5].reason, .awaitingSupport)
            XCTAssertEqual(steps[6].reason, .awaitingSupport)
            XCTAssertEqual(try PoseReplaySquatCycle.replay(session(events)), [1.0])
            for n in events.indices {
                XCTAssertEqual(run(Array(events.prefix(n + 1))), Array(steps.prefix(n + 1)))
            }
        }
    }

    func testReacquiredChainMustAgreeWithOriginalStanceAfterItsGeometryExpires() throws {
        let bottom = [0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90].map { frame($0, nil, .low) }
        let pending = start + bottom + [suspectFoot(1.0)]
        let standing = [frame(1.20, .upright, .upright), frame(1.30, .upright, .upright)]
        XCTAssertEqual(run(pending).last?.reason, .awaitingSupport)
        let restored = pending + [frame(1.10, .mid, .mid)] + standing
        XCTAssertEqual(try PoseReplaySquatCycle.replay(session(restored)), [1.30])
        let moved = run(pending + [frame(1.10, .mid, .mid, footShift: 0.2)] + standing)
        XCTAssertEqual(moved[pending.count].reason, .movingSupport)
        XCTAssertFalse(moved.contains(where: \.counted))
    }

    func testReliableDisplacementCancelsBeforeDuringAndAfterSupportRecovery() {
        let step = frame(0.65, .low, .low, footShift: 0.2)
        for prefix in [confirmedBottom, confirmedBottom + [suspectFoot(0.50)],
                       confirmedBottom + [suspectFoot(0.50), frame(0.57, .low, .low)]] {
            let result = run(prefix + [step] + finish)
            XCTAssertEqual(result[prefix.count].reason, .movingSupport)
            XCTAssertFalse(result.contains(where: \.counted))
        }
    }

    func testLungeWithPartlyHiddenLegCannotUseSupportRecoveryAsDepth() {
        let hidden = frame(0.30, .low, .upright, footShift: 0.2, shiftedSide: .right, unreliableJoint: .rightKnee)
        let early = run(start + [hidden, frame(0.40, .low, .upright), frame(0.53, .low, .upright)] + finish)
        XCTAssertEqual(early[start.count].reason, .movingSupport)
        XCTAssertFalse(early.contains(where: \.counted))

        let prefix = confirmedBottom + [suspectFoot(0.50, side: .right)]
        let revealed = run(prefix + [frame(0.60, .low, .upright), frame(0.72, .mid, .upright)] + finish)
        XCTAssertEqual(revealed[prefix.count].reason, .conflictingLegs)
        XCTAssertFalse(revealed.contains(where: \.counted))
    }

    func testLosingSupportWitnessOrReachingStandingWhileOccludedCancelsCycle() {
        let prefix = confirmedBottom + [suspectFoot(0.50)]
        for frame in [frame(0.60, nil, nil), frame(0.60, nil, .upright), frame(0.60, .low, nil)] {
            let result = run(prefix + [frame, self.frame(0.72, .mid, .mid)] + finish)
            XCTAssertEqual(result[prefix.count].phase, .insufficientData)
            XCTAssertFalse(result.contains(where: \.counted))
        }
    }

    func testDeadlineStartsAtFirstUnverifiedDisplacementAndChecksTheRecoveryFrame() throws {
        let prefix = confirmedBottom + [suspectFoot(0.50), suspectFoot(0.64)]
        let deadline = 0.50 + PoseReplayOcclusionRecovery.continuity
        let restored = prefix + [frame(deadline, .low, .low)] + finish
        XCTAssertEqual(try PoseReplaySquatCycle.replay(session(restored)), [1.06])
        for late in [frame(deadline.nextUp, .low, .low), suspectFoot(deadline.nextUp)] {
            let result = run(prefix + [late] + finish)
            XCTAssertEqual(result[prefix.count].reason, .supportExpired)
            XCTAssertFalse(result.contains(where: \.counted))
        }
    }

    func testUnverifiedSupportCannotJoinInterruptedReturnsOrCarryAcrossReset() {
        let prefix = confirmedBottom + [suspectFoot(0.50), frame(0.60, nil, .mid)]
        let interrupted = run(prefix + [suspectFoot(0.70)] + finish)
        XCTAssertEqual(interrupted[prefix.count].reason, .renewedDescent)
        XCTAssertFalse(interrupted.contains(where: \.counted))
        let boundary = PoseReplayEvent(seconds: 0.70, kind: .reset, pose: nil)
        XCTAssertFalse(run(prefix + [boundary] + finish).contains(where: \.counted))
    }

    func testSupportMustStayVerifiedThroughTheCountedReturn() {
        let regained = confirmedBottom + [suspectFoot(0.50), frame(0.60, .mid, .mid),
                                        frame(0.72, .upright, .upright)]
        let result = run(regained + [frame(0.82, .upright, nil)] + finish)
        XCTAssertEqual(result[regained.count].reason, .interrupted)
        XCTAssertFalse(result.contains(where: \.counted))
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
