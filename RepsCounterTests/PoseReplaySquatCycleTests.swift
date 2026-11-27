import Foundation
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

    func testLongOcclusionPreservesOriginalFootSupportOnEitherSide() throws {
        for side in [BodyLeg.left, .right] {
            let hidden = (5...14).map { index in
                let time = Double(index) / 10
                return side == .left ? frame(time, nil, .low) : frame(time, .low, nil)
            }
            let prefix = confirmedBottom + hidden
            let finish = [frame(1.60, .upright, .upright), frame(1.70, .upright, .upright)]

            let stable = prefix + [frame(1.50, .mid, .mid)] + finish
            XCTAssertEqual(try PoseReplaySquatCycle.replay(session(stable)), [1.70])

            let displaced = frame(1.50, .mid, .mid, footShift: 0.20, shiftedSide: side)
            let result = run(prefix + [displaced] + finish)
            XCTAssertEqual(result[prefix.count].reason, .movingSupport)
            XCTAssertFalse(result.contains(where: \.counted))
        }
    }

    func testPersistentRelativeSupportDisplacementCancelsOnEitherSide() {
        for side in [BodyLeg.left, .right] {
            let first = frame(0.50, .low, .low, footShift: 0.10, shiftedSide: side)
            let second = frame(0.60, .low, .low, footShift: 0.105, shiftedSide: side)
            let tail = [frame(0.70, .mid, .mid), frame(0.80, .upright, .upright),
                        frame(0.90, .upright, .upright)]
            let events = confirmedBottom + [first, second] + tail
            let steps = run(events)
            XCTAssertEqual(steps[confirmedBottom.count].phase, .lowered)
            XCTAssertEqual(steps[confirmedBottom.count + 1].reason, .movingSupport)
            XCTAssertFalse(steps.contains(where: \.counted))
            for index in events.indices {
                XCTAssertEqual(run(Array(events.prefix(index + 1))), Array(steps.prefix(index + 1)))
            }
        }
    }

    func testRelativeSupportNeedsContinuousSameDirectionEvidence() throws {
        for side in [BodyLeg.left, .right] {
            let first = frame(0.50, .low, .low, footShift: 0.10, shiftedSide: side)
            let hidden = side == .left ? frame(0.60, nil, .low) : frame(0.60, .low, nil)
            let alternativeSide: BodyLeg = side == .left ? .right : .left
            let alternatives = [
                frame(0.60, .low, .low),
                frame(0.60, .low, .low, footShift: -0.10, shiftedSide: side),
                frame(0.60, .low, .low, footShift: 0.10, shiftedSide: alternativeSide),
                hidden
            ]
            let tail = [frame(0.80, .mid, .mid), frame(0.90, .upright, .upright),
                        frame(1.00, .upright, .upright)]
            for alternative in alternatives {
                let single = frame(0.70, .low, .low, footShift: 0.10, shiftedSide: side)
                let events = confirmedBottom + [first, alternative, single] + tail
                XCTAssertEqual(try PoseReplaySquatCycle.replay(session(events)), [1.00])
            }
        }
    }

    func testRelativeSupportCannotCancelAnAlreadyCompletedCycle() throws {
        for side in [BodyLeg.left, .right] {
            let completed = confirmedBottom + [frame(0.50, .mid, .mid), frame(0.60, .upright, .upright),
                                              frame(0.70, .upright, .upright)]
            let steps = [frame(0.80, .upright, .upright, footShift: 0.10, shiftedSide: side),
                         frame(0.90, .upright, .upright, footShift: 0.105, shiftedSide: side)]
            XCTAssertEqual(try PoseReplaySquatCycle.replay(session(completed + steps)), [0.70])
        }
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

    func testPrivateReplayCorpus() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip("Private Replay corpus is available only on the simulator or Mac.")
        #else
        guard let directory = ProcessInfo.processInfo.environment["REPS_REPLAY_DIRECTORY"],
              directory.isEmpty == false else {
            throw XCTSkip("Set REPS_REPLAY_DIRECTORY in the test environment to run the private corpus.")
        }

        let expected: [String: [Double]] = [
            "ABB35FBA-0BBB-48E8-9E74-7528C147FE18": [13.081, 18.193, 23.188, 27.782, 32.283],
            "32A56959-9F34-4180-BE54-A55E64116BCB": [9.355, 12.348, 15.555, 19.247, 22.655],
            "8C1F5005-0809-4606-90F0-8690A646C1CB": [10.909, 13.011, 15.110, 17.207, 19.413],
            "6252FD57-0E69-4EC5-A52B-9AF5940A9CD1": [13.875, 15.979, 18.071, 20.183, 22.380],
            "F511B9C7-51D4-4944-B84B-28396481F48B": [11.522, 13.930, 16.121, 18.425, 20.826],
            "E9E2C743-1167-46EA-9F5D-63A8C7CF78FA": [10.759, 12.459, 14.153, 15.758, 17.464, 19.163, 20.857, 22.563, 24.258, 26.064],
            "E436EA81-38ED-48EC-BF92-634EBE8C86E7": [7.477, 9.574, 11.779, 14.080, 16.278],
            "D21E35BB-CCD8-470E-A6BC-CCC875E35B07": [15.435],
            "B8C8293A-F918-4C4B-82FE-4DD61C27B3D1": [11.162, 13.675, 16.276, 19.079],
            "7737C615-4A6A-48A4-8709-99A6671BD995": [25.687, 28.184, 30.680],
            "178F6024-50D1-4448-80A9-890C3DF5FF19": [13.902, 16.098, 18.499],
            "18C7062A-8519-419A-8951-C035422DBA9E": [12.693, 20.495, 22.995],
            "FDF51A66-639F-44E7-B817-8D8E3894617C": [],
            "7AD884A5-D159-439A-98A1-B9A0326F9C09": [30.963, 33.366, 35.765, 38.156, 40.765, 43.265, 45.764, 48.465, 51.161, 53.763],
            "D824221B-3CB4-4A3B-8B0E-E3EE22E77C2F": [18.929, 21.128, 23.331, 25.430, 27.729, 29.830, 32.029, 34.332, 36.731, 39.028],
            "65981B08-DE3F-4A40-922A-95902D4432F9": [],
            "27A9E64C-C4BD-4F93-850A-2863BC0237FD": [11.886, 14.083, 16.586, 18.887, 21.280, 23.391, 25.685, 28.083, 30.486, 32.986],
            "E78DAE64-EBA4-4142-A757-E405AA9D2E8E": [11.720, 13.717, 15.821, 18.021, 20.019, 22.121, 24.122, 28.521],
            "6110846C-428C-4731-B05D-7A9D1FBAFCD1": [],
            "C2228FC2-4D75-41A7-A9A5-61303D5473B9": [],
            "0D1C8B5F-16D4-46F3-AB87-122AEF5CFF44": [16.011, 23.808, 31.006],
            "855F6418-70C1-45D4-B107-D2066E61F2BB": [13.789, 16.583, 19.177, 22.079, 25.075, 55.983, 61.785, 68.386],
            "DC01024F-7EDE-4D67-8B14-1FFE7AC0ADC3": [12.479, 14.980, 17.580, 20.181, 23.081, 47.985, 53.882],
            "3D1059FB-E0F5-467C-9F49-2CDB3E1994E0": [12.207, 16.507]
        ]
        let baselineTotal = expected.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(baselineTotal, 112)
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter {
            $0.lastPathComponent.hasPrefix("RepsCounter-PoseReplay-") &&
                $0.pathExtension.lowercased() == "json"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        let expectedNames = Set(expected.keys.map { "RepsCounter-PoseReplay-\($0).json" })
        let actualNames = Set(files.map(\.lastPathComponent))
        let missing = expectedNames.subtracting(actualNames).sorted()
        let unexpected = actualNames.subtracting(expectedNames).sorted()
        XCTAssertEqual(files.count, expected.count)
        XCTAssertTrue(missing.isEmpty, "Missing: \(missing)")
        XCTAssertTrue(unexpected.isEmpty, "Unexpected: \(unexpected)")

        var report = ["file,baseline_count,standard_count,bypass_count,baseline_seconds,standard_seconds,bypass_seconds,status"]
        var trace = ["file,variant,seconds,phase,reason,counted"]
        var total = 0
        var bypassTotal = 0
        var processed = 0
        var matched = 0
        let decoder = JSONDecoder()

        for file in files {
            let identifier = String(file.deletingPathExtension().lastPathComponent.dropFirst("RepsCounter-PoseReplay-".count))
            guard let baseline = expected[identifier] else { continue }
            do {
                let session = try decoder.decode(PoseReplaySession.self, from: Data(contentsOf: file))
                let times = try PoseReplaySquatCycle.replay(session) { seconds, step in
                    trace.append("\(file.lastPathComponent),standard,\(seconds),\(step.phase.rawValue),\(step.reason.rawValue),\(step.counted)")
                }
                let bypassTimes = try PoseReplaySquatCycle.replayIgnoringSupportChecks(session) { seconds, step in
                    trace.append("\(file.lastPathComponent),bypass,\(seconds),\(step.phase.rawValue),\(step.reason.rawValue),\(step.counted)")
                }
                let matches = times.count == baseline.count &&
                    zip(times, baseline).allSatisfy { abs($0.0 - $0.1) <= 0.000501 }
                if matches { matched += 1 }
                let actualText = times.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ";")
                let expectedText = baseline.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ";")
                let bypassText = bypassTimes.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ";")
                let status = matches ? "MATCH" : "DIFF"
                let line = "\(file.lastPathComponent),\(baseline.count),\(times.count),\(bypassTimes.count),\(expectedText),\(actualText),\(bypassText),\(status)"
                report.append(line)
                print("REPS_SUPPORT_AUDIT \(line)")
                total += times.count
                bypassTotal += bypassTimes.count
                processed += 1
                XCTAssertTrue(matches, "\(file.lastPathComponent): expected [\(expectedText)], actual [\(actualText)]")
            } catch {
                report.append("\(file.lastPathComponent),\(baseline.count),,,,,,ERROR")
                XCTFail("\(file.lastPathComponent): \(error)")
            }
        }

        let summary = "REPS_CORPUS_SUMMARY processed=\(processed)/\(expected.count) matched=\(matched)/\(expected.count) standard=\(total) expected=\(baselineTotal) bypass=\(bypassTotal)"
        print(summary)
        let attachment = XCTAttachment(string: report.joined(separator: "\n") + "\n" + summary)
        attachment.name = "Support policy comparison"
        attachment.lifetime = .keepAlways
        add(attachment)
        let traceAttachment = XCTAttachment(string: trace.joined(separator: "\n"))
        traceAttachment.name = "Support policy per-frame trace"
        traceAttachment.lifetime = .keepAlways
        add(traceAttachment)
        XCTAssertEqual(processed, expected.count)
        XCTAssertEqual(matched, expected.count)
        XCTAssertEqual(total, baselineTotal)
        #endif
    }
}
