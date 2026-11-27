import Foundation
import CoreGraphics
import XCTest
@testable import RepsCounter

final class PoseReplaySquatCycleTests: XCTestCase {
    private enum Posture {
        case upright, nearStanding, mid, low, perspective, shallow, borderline, supportOnly, corroborating
        case ascentJitter, largerRegression, repeatedRegression

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
            case .corroborating: return (0.50, 0.42, 0.14)
            case .ascentJitter: return (0.60, 0.50, 0.17)
            case .largerRegression: return (0.60, 0.50, 0.20)
            case .repeatedRegression: return (0.63, 0.50, 0.21)
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

    func testCorroboratedWeakHipCanConfirmDepthOnEitherSide() throws {
        for side in [BodyLeg.left, .right] {
            let samples = [0.30, 0.40, 0.50, 0.60, 0.70].map { time in
                frame(time, side == .left ? .low : .corroborating,
                      side == .left ? .corroborating : .low,
                      unreliableJoint: side == .left ? .leftHip : .rightHip)
            }
            let recorded = session(start + samples + finish)
            XCTAssertTrue(try PoseReplaySquatCycle.replay(recorded).isEmpty)
            var confirmations = 0
            let times = try PoseReplaySquatCycle.replayWithCorroboratedHipDepth(recorded) { _, step in
                if step.reason == .corroboratedHipDepth { confirmations += 1 }
            }
            XCTAssertEqual(confirmations, 1)
            XCTAssertEqual(times, [1.06])
        }
    }

    func testWeakHipCannotCountWithoutRepeatedCorroborationAndNegativeHipKneeHeight() throws {
        let single = [frame(0.30, .low, .corroborating, unreliableJoint: .leftHip)]
            + [0.40, 0.50, 0.60, 0.70].map { frame($0, .mid, .mid) }
        let shallow = [0.30, 0.40, 0.50, 0.60, 0.70].map {
            frame($0, .borderline, .corroborating, unreliableJoint: .leftHip)
        }
        let uncorroborated = [0.30, 0.40, 0.50, 0.60, 0.70].map {
            frame($0, .low, nil, unreliableJoint: .leftHip)
        }
        let unreliableKnee = [0.30, 0.40, 0.50, 0.60, 0.70].map {
            frame($0, .low, .corroborating, unreliableJoint: .leftKnee)
        }
        for samples in [single, shallow, uncorroborated, unreliableKnee] {
            XCTAssertTrue(try PoseReplaySquatCycle.replayWithCorroboratedHipDepth(session(start + samples + finish)).isEmpty)
        }
    }

    func testCorroboratedWeakHipStillRequiresReturnToStanding() throws {
        let samples = [0.30, 0.40, 0.50, 0.60, 0.70].map {
            frame($0, .low, .corroborating, unreliableJoint: .leftHip)
        }
        let unfinished = [frame(0.85, .mid, .mid), frame(0.95, .mid, .mid), frame(1.06, .mid, .mid)]
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithCorroboratedHipDepth(session(start + samples + unfinished)).isEmpty)
    }

    func testAscentToleranceAllowsOneSmallRegressionWithBilateralRise() throws {
        for side in [BodyLeg.left, .right] {
            let recorded = session(confirmedBottom + [
                frame(0.50, side == .left ? nil : .shallow, side == .left ? .shallow : nil),
                frame(0.60, side == .left ? .perspective : .mid, side == .left ? .mid : .perspective),
                frame(0.70, side == .left ? .ascentJitter : .nearStanding, side == .left ? .nearStanding : .ascentJitter),
                frame(0.80, side == .left ? .nearStanding : .upright, side == .left ? .upright : .nearStanding),
                frame(0.90, .upright, .upright), frame(1.00, .upright, .upright)
            ])
            XCTAssertTrue(try PoseReplaySquatCycle.replayWithCorroboratedHipDepth(recorded).isEmpty)
            var tolerated = 0
            let times = try PoseReplaySquatCycle.replayWithAscentTolerance(recorded) { _, step in
                if step.reason == .toleratedAscentRegression { tolerated += 1 }
            }
            XCTAssertEqual(tolerated, 1)
            XCTAssertEqual(times, [1.00])
        }
    }

    func testAscentToleranceRejectsLargerRepeatedOrUnobservedRegression() throws {
        let suffix = [frame(0.90, .upright, .upright), frame(1.00, .upright, .upright)]
        let cases = [
            [frame(0.70, .nearStanding, .largerRegression), frame(0.80, .upright, .nearStanding)],
            [frame(0.70, .nearStanding, .ascentJitter), frame(0.80, .upright, .repeatedRegression)],
            [frame(0.70, .nearStanding, nil), frame(0.80, .upright, .nearStanding)],
            [frame(0.70, .nearStanding, .low), frame(0.80, .upright, .nearStanding)]
        ]
        for samples in cases {
            XCTAssertTrue(try PoseReplaySquatCycle.replayWithAscentTolerance(session(reacquiredAscent + samples + suffix)).isEmpty)
        }
    }

    func testAscentToleranceRequiresBilateralStandingAfterRegression() throws {
        let samples = [frame(0.70, .nearStanding, .ascentJitter),
                       frame(0.80, .upright, .nearStanding),
                       frame(0.90, .upright, .nearStanding), frame(1.00, .upright, .nearStanding)]
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithAscentTolerance(session(reacquiredAscent + samples)).isEmpty)
    }

    private func projectionFrame(_ time: Double, stage: Int, mirrored: Bool = false,
                                 partial: Bool = false, opposing: Bool = false,
                                 footShift: Double = 0, distorted: Bool = false) -> PoseReplayEvent {
        let low = stage == 2
        let leftHip = stage == 0 ? 0.50 : (low ? (partial ? 0.38 : 0.32) : 0.39)
        let rightHip = stage == 0 ? 0.48 : (low ? (partial ? 0.40 : 0.34) : 0.40)
        var joints: [BodyJoint: JointPoint] = [:]
        for (side, hip, ankle, base) in [(BodyLeg.left, leftHip, 0.21, 0.3), (.right, rightHip, 0.11, 0.7)] {
            let isLeft = side == .left
            let forward = stage == 0 ? 0 : (distorted && isLeft ? 0.6 : (low ? (opposing && !isLeft ? 0.04 : 0.10) : 0.06))
            let knee = stage == 0 ? (hip + ankle) / 2
                : (low ? (isLeft ? (partial ? 0.35 : 0.34) : (opposing ? 0.25 : 0.30))
                   : (isLeft ? 0.35 : 0.34))
            let targetLeft = mirrored ? !isLeft : isLeft
            let coordinates = [(base, hip), (base + forward, knee), (base + (isLeft ? footShift : 0), ankle)]
            let names: [BodyJoint] = targetLeft ? [.leftHip, .leftKnee, .leftAnkle]
                : [.rightHip, .rightKnee, .rightAnkle]
            for (name, point) in zip(names, coordinates) {
                joints[name] = JointPoint(location: CGPoint(x: mirrored ? 1 - point.0 : point.0, y: point.1),
                                          confidence: 0.9)
            }
        }
        return .init(seconds: time, kind: .pose,
                     pose: .init(from: BodyPose(joints: joints, aspectRatio: 1, rotationAngle: 90)))
    }

    private func projectionCycle(mirrored: Bool = false, partial: Bool = false) -> PoseReplaySession {
        session([
            projectionFrame(0, stage: 0, mirrored: mirrored),
            projectionFrame(0.1, stage: 0, mirrored: mirrored),
            projectionFrame(0.2, stage: 1, mirrored: mirrored),
            projectionFrame(0.3, stage: 2, mirrored: mirrored, partial: partial),
            projectionFrame(0.4, stage: 2, mirrored: mirrored, partial: partial),
            projectionFrame(0.5, stage: 2, mirrored: mirrored, partial: partial),
            projectionFrame(0.6, stage: 1, mirrored: mirrored),
            projectionFrame(0.8, stage: 0, mirrored: mirrored),
            projectionFrame(0.9, stage: 0, mirrored: mirrored)
        ])
    }

    func testProjectionEvidenceIsOptInAndSymmetric() throws {
        for mirrored in [false, true] {
            let recording = projectionCycle(mirrored: mirrored)
            XCTAssertTrue(try PoseReplaySquatCycle.replayWithAscentTolerance(recording).isEmpty)
            var accepted = 0
            let times = try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(recording) { _, step in
                if step.projectionConflictAccepted { accepted += 1 }
            }
            XCTAssertGreaterThan(accepted, 0)
            XCTAssertEqual(times, [0.9])
        }
    }

    func testProjectionEvidenceCannotConfirmPartialDepth() throws {
        for mirrored in [false, true] {
            XCTAssertTrue(try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(
                projectionCycle(mirrored: mirrored, partial: true)).isEmpty)
        }
    }

    func testProjectionEvidenceRejectsOpposingKneeMotionAndChangingSegments() throws {
        for mirrored in [false, true] {
            for distorted in [false, true] {
                let events = [
                    projectionFrame(0, stage: 0, mirrored: mirrored),
                    projectionFrame(0.1, stage: 0, mirrored: mirrored),
                    projectionFrame(0.2, stage: 1, mirrored: mirrored),
                    projectionFrame(0.3, stage: 2, mirrored: mirrored, opposing: !distorted, distorted: distorted)
                ]
                var last: PoseReplaySquatCycle.Step?
                XCTAssertTrue(try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(session(events)) { _, step in
                    last = step
                }.isEmpty)
                XCTAssertEqual(last?.reason, .conflictingLegs)
                XCTAssertEqual(last?.projectionConflictAccepted, false)
            }
        }
    }

    func testProjectionEvidencePreservesUprightConflictAndMovingSupport() throws {
        let bad = [frame(0.3, .low, .upright), frame(0.3, .low, .low, footShift: 0.2)]
        for event in bad {
            XCTAssertTrue(try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(
                session(start + [event] + finish)).isEmpty)
        }
        let events = [projectionFrame(0, stage: 0), projectionFrame(0.1, stage: 0),
                      projectionFrame(0.2, stage: 1), projectionFrame(0.3, stage: 2, footShift: 0.2)]
        var reason: PoseReplaySquatCycle.Reason?
        _ = try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(session(events)) { _, step in
            reason = step.reason
        }
        XCTAssertEqual(reason, .movingSupport)
    }

    func testProjectionEvidenceCannotCountUnfinishedOrRepeatCompletedMovement() throws {
        let recorded = projectionCycle()
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(
            session(Array(recorded.events.prefix(7)))).isEmpty)
        let events = recorded.events + [projectionFrame(1.0, stage: 0), projectionFrame(1.1, stage: 0)]
        XCTAssertEqual(try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(session(events)), [0.9])
    }

    func testProjectionEvidenceIsCausalAndResetDoesNotCarryContext() throws {
        let recording = projectionCycle()
        let full = try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(recording)
        for count in 1...recording.events.count {
            let prefix = Array(recording.events.prefix(count))
            XCTAssertEqual(try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(session(prefix)),
                           full.filter { $0 <= prefix.last!.seconds })
        }
        let events = Array(recording.events.prefix(3))
            + [PoseReplayEvent(seconds: 0.25, kind: .reset, pose: nil)]
            + Array(recording.events.dropFirst(3))
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(session(events)).isEmpty)
    }

    func testProjectionEvidenceRejectsLossOfBothLegsAndStaleHistory() throws {
        let events = Array(projectionCycle().events.prefix(3))
            + [PoseReplayEvent(seconds: 0.3, kind: .pose, pose: nil),
               PoseReplayEvent(seconds: 0.4, kind: .pose, pose: nil),
               PoseReplayEvent(seconds: 0.5, kind: .pose, pose: nil)]
            + [projectionFrame(0.6, stage: 2), projectionFrame(0.7, stage: 2),
               projectionFrame(0.8, stage: 0), projectionFrame(0.9, stage: 0)]
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(session(events)).isEmpty)
    }

    private func recoverySession(_ events: [PoseReplayEvent], side: BodyLeg = .left) -> PoseReplaySession {
        session(events.map { event in
            guard let pose = event.pose?.restore() else { return event }
            var joints = pose.joints
            let ankle: BodyJoint = side == .left ? .rightAnkle : .leftAnkle
            if let point = joints[ankle] {
                joints[ankle] = JointPoint(location: CGPoint(x: point.location.x, y: 0),
                                           confidence: point.confidence)
            }
            return .init(seconds: event.seconds, kind: event.kind,
                         pose: .init(from: BodyPose(joints: joints, aspectRatio: pose.aspectRatio,
                                                   rotationAngle: pose.rotationAngle)))
        })
    }

    private func recoveryFrame(_ time: Double, _ posture: Posture, side: BodyLeg,
                               weak: Bool = false) -> PoseReplayEvent {
        frame(time, side == .left ? posture : .corroborating, side == .left ? .corroborating : posture,
              unreliableJoint: weak ? (side == .left ? .leftHip : .rightHip) : nil)
    }

    private func recoveryCycle(side: BodyLeg = .left) -> PoseReplaySession {
        recoverySession(start + [recoveryFrame(0.3, .low, side: side),
                         recoveryFrame(0.4, .low, side: side),
                         recoveryFrame(0.5, .low, side: side, weak: true),
                         frame(0.6, .mid, .mid), frame(0.7, .upright, .upright),
                         frame(0.8, .upright, .upright)], side: side)
    }

    func testDepthRecoveryCombinesTwoStrictFramesWithOneCorroboratedWeakFrameOnEitherSide() throws {
        for side in [BodyLeg.left, .right] {
            let recording = recoveryCycle(side: side)
            XCTAssertTrue(try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(recording).isEmpty)
            var confirmations = 0
            let times = try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recording) { _, step in
                if step.reason == .recoveredDepthEvidence { confirmations += 1 }
            }
            XCTAssertEqual(confirmations, 1)
            XCTAssertEqual(times, [0.8])
        }
    }

    func testDepthRecoveryRejectsOneStrictFrameAndWeakNoiseWithoutHistory() throws {
        let recording = recoveryCycle()
        let insufficient = recording.events.filter { $0.seconds != 0.4 }
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(insufficient)).isEmpty)
        let weakOnly = start + [recoveryFrame(0.3, .low, side: .left, weak: true)]
            + [frame(0.4, .mid, .mid), frame(0.5, .upright, .upright), frame(0.6, .upright, .upright)]
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(weakOnly)).isEmpty)
    }

    func testDepthRecoveryRejectsShallowAndBrokenDepthSequences() throws {
        let shallow = start + [recoveryFrame(0.3, .shallow, side: .left),
                               recoveryFrame(0.4, .shallow, side: .left),
                               recoveryFrame(0.5, .shallow, side: .left, weak: true)]
            + [frame(0.6, .mid, .mid), frame(0.7, .upright, .upright), frame(0.8, .upright, .upright)]
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(shallow)).isEmpty)
        let events = start + [recoveryFrame(0.3, .low, side: .left),
                              recoveryFrame(0.35, .shallow, side: .left),
                              recoveryFrame(0.4, .low, side: .left),
                              recoveryFrame(0.5, .low, side: .left, weak: true)]
            + [frame(0.6, .mid, .mid), frame(0.7, .upright, .upright), frame(0.8, .upright, .upright)]
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(events)).isEmpty)
    }

    func testDepthRecoveryDoesNotUseMissingOrUnreliableKneeAsEvidence() throws {
        for joint in [BodyJoint.leftKnee, .leftAnkle] {
            let events = start + [recoveryFrame(0.3, .low, side: .left),
                                  recoveryFrame(0.4, .low, side: .left),
                                  frame(0.5, .low, .perspective, unreliableJoint: joint),
                                  frame(0.6, .mid, .mid), frame(0.7, .upright, .upright),
                                  frame(0.8, .upright, .upright)]
            XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(events)).isEmpty)
        }
        let missing = start + [recoveryFrame(0.3, .low, side: .left),
                               recoveryFrame(0.4, .low, side: .left),
                               frame(0.5, nil, .perspective), frame(0.6, .mid, .mid),
                               frame(0.7, .upright, .upright), frame(0.8, .upright, .upright)]
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(missing)).isEmpty)
    }

    func testDepthRecoveryExpiresEvidenceAndCannotJoinResetOrRepeatedTimestamp() throws {
        let repeated = start + [recoveryFrame(0.3, .low, side: .left),
                                recoveryFrame(0.3, .low, side: .left),
                                recoveryFrame(0.4, .low, side: .left, weak: true),
                                frame(0.5, .mid, .mid), frame(0.6, .upright, .upright),
                                frame(0.7, .upright, .upright)]
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(repeated)).isEmpty)
        let expired = start + [recoveryFrame(0.3, .low, side: .left),
                               recoveryFrame(0.4, .low, side: .left),
                               frame(0.5, nil, .perspective),
                               recoveryFrame(0.6, .low, side: .left, weak: true),
                               frame(0.7, .mid, .mid), frame(0.8, .upright, .upright),
                               frame(0.9, .upright, .upright)]
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(expired)).isEmpty)
        let interrupted = Array(recoveryCycle().events.prefix(5))
            + [PoseReplayEvent(seconds: 0.45, kind: .reset, pose: nil)]
            + Array(recoveryCycle().events.dropFirst(5))
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(interrupted)).isEmpty)
    }

    func testDepthRecoveryStillRejectsContradictoryLegAndFootShift() throws {
        for last in [frame(0.5, .low, .upright, unreliableJoint: .leftHip),
                     frame(0.5, .low, .perspective, footShift: 0.2, unreliableJoint: .leftHip)] {
            let events = start + [recoveryFrame(0.3, .low, side: .left),
                                  recoveryFrame(0.4, .low, side: .left), last,
                                  frame(0.6, .mid, .mid), frame(0.7, .upright, .upright),
                                  frame(0.8, .upright, .upright)]
            XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(events)).isEmpty)
        }
    }

    func testDepthRecoveryIsCausalNeedsCompletionAndCannotDoubleCount() throws {
        let recording = recoveryCycle()
        let complete = try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recording)
        for count in 1...recording.events.count {
            let events = Array(recording.events.prefix(count))
            XCTAssertEqual(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(events)),
                           complete.filter { $0 <= events.last!.seconds })
        }
        let lingering = recording.events + [frame(0.9, .upright, .upright), frame(1.0, .upright, .upright)]
        XCTAssertEqual(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recoverySession(lingering)), [0.8])
    }

    func testDepthRecoveryKeepsWeakHipConfidenceFloor() throws {
        var events = recoveryCycle().events
        let index = events.firstIndex { $0.seconds == 0.5 }!
        let pose = events[index].pose!.restore()
        var joints = pose.joints
        let hip = joints[.leftHip]!
        joints[.leftHip] = JointPoint(location: hip.location, confidence: 0.29)
        events[index] = .init(seconds: 0.5, kind: .pose,
                              pose: .init(from: BodyPose(joints: joints, aspectRatio: pose.aspectRatio,
                                                        rotationAngle: pose.rotationAngle)))
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(session(events)).isEmpty)
    }

    func testPrivateDepthRecoveryTargetRecording() throws {
        guard let path = ProcessInfo.processInfo.environment["REPS_DEPTH_RECOVERY_RECORDING"] else {
            throw XCTSkip("Set REPS_DEPTH_RECOVERY_RECORDING to validate the private target recording.")
        }
        let recording = try JSONDecoder().decode(PoseReplaySession.self,
                                                 from: Data(contentsOf: URL(fileURLWithPath: path)))
        let baseline = try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(recording)
        let recovered = try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recording)
        XCTAssertEqual(baseline.count, 8)
        XCTAssertEqual(recovered.count, 9)
        XCTAssertTrue(baseline.allSatisfy { recovered.contains($0) })
        let added = recovered.filter { !baseline.contains($0) }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first ?? 0, 11.274751333, accuracy: 0.000000001)
    }

    private func interruptedAscentFrame(_ time: Double, stage: Int, mirrored: Bool = false,
                                       largerRegression: Bool = false, lowering: Bool = false,
                                       footShift: Double = 0) -> PoseReplayEvent {
        var joints: [BodyJoint: JointPoint] = [:]
        for side in [BodyLeg.left, .right] {
            let source = side == .left
            if source && (stage == 3 || stage == 4) { continue }
            let hip: Double
            let ankle = source ? (stage == 5 ? 0.225 : 0.2) : 0.1
            let forward: Double
            let knee: Double
            switch stage {
            case 0:
                hip = 0.5
                forward = 0
                knee = (hip + ankle) / 2
            case 1:
                hip = 0.42
                forward = 0.04
                knee = (hip + ankle) / 2
            case 2:
                hip = 0.34
                forward = source ? 0.025 : 0.08
                knee = source ? 0.34 : 0.35
            case 3:
                hip = 0.35
                forward = 0.08
                knee = (hip + ankle) / 2
            case 4:
                hip = 0.37
                forward = 0.08
                knee = (hip + ankle) / 2
            case 5:
                hip = source ? (lowering ? 0.33 : 0.35) : 0.38
                forward = source ? (largerRegression ? 0.06 : 0.026) : 0.06
                knee = source ? hip : (hip + ankle) / 2
            default:
                hip = source ? 0.42 : 0.44
                forward = 0.04
                knee = (hip + ankle) / 2
            }
            let base = source ? 0.3 : 0.7
            let isLeft = mirrored ? !source : source
            let names: [BodyJoint] = isLeft ? [.leftHip, .leftKnee, .leftAnkle] : [.rightHip, .rightKnee, .rightAnkle]
            let points = [(base, hip), (base + forward, knee), (base + (source ? footShift : 0), ankle)]
            for (name, point) in zip(names, points) {
                joints[name] = JointPoint(location: CGPoint(x: mirrored ? 1 - point.0 : point.0, y: point.1),
                                          confidence: 0.9)
            }
        }
        return .init(seconds: time, kind: .pose,
                     pose: .init(from: BodyPose(joints: joints, aspectRatio: 1, rotationAngle: 90)))
    }

    private func interruptedAscentCycle(mirrored: Bool = false) -> PoseReplaySession {
        session([(0.0, 0), (0.1, 0), (0.2, 1), (0.3, 2), (0.4, 2),
                 (0.5, 3), (0.6, 4), (0.7, 5), (0.8, 6), (0.9, 0), (1.0, 0)].map {
            interruptedAscentFrame($0.0, stage: $0.1, mirrored: mirrored)
        })
    }

    func testInterruptedAscentRecoveryReusesToleranceAndRequiresBilateralCompletion() throws {
        for mirrored in [false, true] {
            let recorded = interruptedAscentCycle(mirrored: mirrored)
            XCTAssertTrue(try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recorded).isEmpty)
            var recovered = 0
            let times = try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(recorded) { _, step in
                if step.reason == .recoveredInterruptedAscent { recovered += 1 }
            }
            XCTAssertEqual(recovered, 1)
            XCTAssertEqual(times, [1.0])
        }
    }

    func testInterruptedAscentRecoveryRejectsRealDescentAndLargeRegression() throws {
        for mirrored in [false, true] {
            for larger in [false, true] {
                var events = interruptedAscentCycle(mirrored: mirrored).events
                events[7] = interruptedAscentFrame(0.7, stage: 5, mirrored: mirrored,
                                                  largerRegression: larger, lowering: !larger)
                XCTAssertTrue(try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(session(events)).isEmpty)
            }
        }
    }

    func testInterruptedAscentRecoveryCannotReuseConsumedToleranceOrLoseJoints() throws {
        let base = interruptedAscentCycle().events
        for replacement in [frame(0.8, nil, nil), frame(0.8, nil, .nearStanding), frame(0.8, .low, .low),
                            interruptedAscentFrame(0.8, stage: 5, largerRegression: true)] {
            var events = base
            events[8] = replacement
            XCTAssertTrue(try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(session(events)).isEmpty)
        }
    }

    func testInterruptedAscentRecoveryKeepsSupportAndDepthRequirements() throws {
        var shifted = interruptedAscentCycle().events
        shifted[7] = interruptedAscentFrame(0.7, stage: 5, footShift: 0.2)
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(session(shifted)).isEmpty)
        let noDepth = interruptedAscentCycle().events.filter { $0.seconds != 0.3 && $0.seconds != 0.4 }
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(session(noDepth)).isEmpty)
    }

    func testInterruptedAscentRecoveryIsCausalAndCannotCountIncompleteOrDuplicateReturn() throws {
        let recorded = interruptedAscentCycle()
        let complete = try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(recorded)
        for length in 1...recorded.events.count {
            let events = Array(recorded.events.prefix(length))
            XCTAssertEqual(try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(session(events)),
                           complete.filter { $0 <= events.last!.seconds })
        }
        let events = recorded.events + [interruptedAscentFrame(1.1, stage: 0),
                                         interruptedAscentFrame(1.2, stage: 0)]
        XCTAssertEqual(try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(session(events)), [1.0])
    }

    func testInterruptedAscentRecoveryDoesNotCarryResetOrExpiredHistory() throws {
        let recorded = interruptedAscentCycle()
        let reset = Array(recorded.events.prefix(7))
            + [PoseReplayEvent(seconds: 0.65, kind: .reset, pose: nil)]
            + Array(recorded.events.dropFirst(7))
        XCTAssertTrue(try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(session(reset)).isEmpty)
        let gap = (6...12).map { interruptedAscentFrame(Double($0) / 10, stage: 4) }
        let events = Array(recorded.events.prefix(6)) + gap
            + [interruptedAscentFrame(1.3, stage: 5), interruptedAscentFrame(1.4, stage: 6),
               interruptedAscentFrame(1.5, stage: 0), interruptedAscentFrame(1.6, stage: 0)]
        var recovered = 0
        let times = try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(session(events)) { _, step in
            if step.reason == .recoveredInterruptedAscent { recovered += 1 }
        }
        XCTAssertEqual(recovered, 0)
        XCTAssertEqual(times, try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(session(events)))
    }

    func testPrivateInterruptedAscentTargetRecording() throws {
        guard let path = ProcessInfo.processInfo.environment["REPS_DEPTH_RECOVERY_RECORDING"] else {
            throw XCTSkip("Set REPS_DEPTH_RECOVERY_RECORDING to validate the private target recording.")
        }
        let recorded = try JSONDecoder().decode(PoseReplaySession.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: path)))
        let baseline = try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(recorded)
        let recovered = try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(recorded)
        XCTAssertEqual(baseline.count, 9)
        XCTAssertEqual(recovered.count, 10)
        XCTAssertTrue(baseline.allSatisfy { recovered.contains($0) })
        let added = recovered.filter { !baseline.contains($0) }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first ?? 0, 51.673201917, accuracy: 0.000000001)
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
        let depthAdditions: [String: [Double]] = [
            "178F6024-50D1-4448-80A9-890C3DF5FF19": [20.800],
            "3D1059FB-E0F5-467C-9F49-2CDB3E1994E0": [14.307, 18.808, 21.205, 41.407],
            "7AD884A5-D159-439A-98A1-B9A0326F9C09": [62.963, 68.064],
            "B8C8293A-F918-4C4B-82FE-4DD61C27B3D1": [21.676],
            "E78DAE64-EBA4-4142-A757-E405AA9D2E8E": [26.323, 30.716],
            "F511B9C7-51D4-4944-B84B-28396481F48B": [27.620]
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

        var report = ["file,baseline_count,standard_count,bypass_count,depth_count,ascent_count,baseline_seconds,standard_seconds,bypass_seconds,depth_seconds,ascent_seconds,status"]
        var trace = ["file,variant,seconds,phase,reason,counted"]
        var total = 0
        var bypassTotal = 0
        var depthTotal = 0
        var ascentTotal = 0
        var depthMatched = 0
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
                let depthTimes = try PoseReplaySquatCycle.replayWithCorroboratedHipDepth(session) { seconds, step in
                    trace.append("\(file.lastPathComponent),depth,\(seconds),\(step.phase.rawValue),\(step.reason.rawValue),\(step.counted)")
                }
                let ascentTimes = try PoseReplaySquatCycle.replayWithAscentTolerance(session) { seconds, step in
                    trace.append("\(file.lastPathComponent),ascent,\(seconds),\(step.phase.rawValue),\(step.reason.rawValue),\(step.counted)")
                }
                let projectionTimes = try PoseReplaySquatCycle.replayWithProjectionConflictEvidence(session)
                let recoveryTimes = try PoseReplaySquatCycle.replayWithDepthEvidenceRecovery(session)
                let ascentRecoveryTimes = try PoseReplaySquatCycle.replayWithInterruptedAscentRecovery(session)
                XCTAssertEqual(ascentRecoveryTimes, recoveryTimes, "\(file.lastPathComponent): PR50 events changed")
                XCTAssertEqual(recoveryTimes, projectionTimes, "\(file.lastPathComponent): PR49 events changed")
                XCTAssertEqual(projectionTimes, ascentTimes, "\(file.lastPathComponent): PR48 events changed")
                let expectedDepth = (baseline + (depthAdditions[identifier] ?? [])).sorted()
                let depthMatches = depthTimes.count == expectedDepth.count &&
                    zip(depthTimes, expectedDepth).allSatisfy { abs($0.0 - $0.1) <= 0.000501 }
                if depthMatches { depthMatched += 1 }
                XCTAssertTrue(depthMatches, "\(file.lastPathComponent): PR47 depth baseline changed")
                let matches = times.count == baseline.count &&
                    zip(times, baseline).allSatisfy { abs($0.0 - $0.1) <= 0.000501 }
                if matches { matched += 1 }
                let actualText = times.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ";")
                let expectedText = baseline.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ";")
                let bypassText = bypassTimes.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ";")
                let depthText = depthTimes.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ";")
                let status = matches ? "MATCH" : "DIFF"
                let ascentText = ascentTimes.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ";")
                let line = "\(file.lastPathComponent),\(baseline.count),\(times.count),\(bypassTimes.count),\(depthTimes.count),\(ascentTimes.count),\(expectedText),\(actualText),\(bypassText),\(depthText),\(ascentText),\(status)"
                report.append(line)
                print("REPS_ASCENT_AUDIT \(line)")
                total += times.count
                bypassTotal += bypassTimes.count
                depthTotal += depthTimes.count
                ascentTotal += ascentTimes.count
                processed += 1
                XCTAssertTrue(matches, "\(file.lastPathComponent): expected [\(expectedText)], actual [\(actualText)]")
            } catch {
                report.append("\(file.lastPathComponent),\(baseline.count),,,,,,,,,,ERROR")
                XCTFail("\(file.lastPathComponent): \(error)")
            }
        }

        let summary = "REPS_CORPUS_SUMMARY processed=\(processed)/\(expected.count) matched=\(matched)/\(expected.count) standard=\(total) expected=\(baselineTotal) bypass=\(bypassTotal) depth=\(depthTotal) depthMatched=\(depthMatched)/\(expected.count) ascent=\(ascentTotal)"
        print(summary)
        let attachment = XCTAttachment(string: report.joined(separator: "\n") + "\n" + summary)
        attachment.name = "Ascent tolerance comparison"
        attachment.lifetime = .keepAlways
        add(attachment)
        let traceAttachment = XCTAttachment(string: trace.joined(separator: "\n"))
        traceAttachment.name = "Ascent tolerance per-frame trace"
        traceAttachment.lifetime = .keepAlways
        add(traceAttachment)
        XCTAssertEqual(processed, expected.count)
        XCTAssertEqual(matched, expected.count)
        XCTAssertEqual(total, baselineTotal)
        XCTAssertEqual(bypassTotal, 133)
        XCTAssertEqual(depthTotal, 123)
        XCTAssertEqual(depthMatched, expected.count)
        XCTAssertEqual(ascentTotal, 124)
        #endif
    }
}
