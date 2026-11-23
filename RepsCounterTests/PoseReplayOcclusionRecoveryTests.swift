#if DEBUG
import CoreGraphics
import XCTest
@testable import RepsCounter

final class PoseReplayOcclusionRecoveryTests: XCTestCase {
    func testTwoDepthFramesSurviveShortOcclusionOnlyWhenOriginalLegConfirmsThird() throws {
        var f = Trace()
        f.add(.up, .up, 5)
        f.add(.deep, .projected, 2)
        f.add(.hiddenHip, .projected, 6)
        f.add(.deep, .projected, 1)
        f.add(.up, .up, 10)
        let a = try f.replay()
        XCTAssertEqual(a.baseline.depthSamples[6].phase, .standing)
        XCTAssertEqual(a.baseline.depthSamples[7].phase, .seekingStanding)
        XCTAssertEqual(a.baseline.depthSamples[7].selectedLeg, .right)
        XCTAssertEqual(a.baseline.countedAtSeconds, [])
        XCTAssertEqual(a.countedAtSeconds, [1.6])
        XCTAssertEqual(a.supplementalAtSeconds, a.countedAtSeconds)
        XCTAssertEqual(try f.replay().countedAtSeconds, a.countedAtSeconds)

        var noThird = Trace()
        noThird.add(.up, .up, 5)
        noThird.add(.deep, .projected, 2)
        noThird.add(.hiddenHip, .projected, 6)
        noThird.add(.up, .up, 10)
        XCTAssertEqual(try noThird.replay().countedAtSeconds, [])
    }

    func testSwitchAfterLoweredRestoresOnceOnStanding() throws {
        var f = Trace()
        f.add(.up, .up, 6)
        f.add(.deep, .projected, 10)
        f.add(.hiddenHip, .projected, 3)
        f.add(.up, .up, 12)
        let result = try f.replay()
        XCTAssertEqual(result.baseline.depthSamples[15].phase, .lowered)
        XCTAssertEqual(result.baseline.depthSamples[16].phase, .seekingStanding)
        XCTAssertEqual(result.baseline.countedAtSeconds, [])
        XCTAssertEqual(result.countedAtSeconds, [2.1])
    }

    func testRightLegRecoversSymmetricallyAfterMissingJointInV2() throws {
        var f = Trace()
        f.add(.up, .up, 5)
        f.add(.projected, .deep, 2)
        f.add(.projected, .missingHip, 4)
        f.add(.projected, .deep, 1)
        f.add(.up, .up, 9)
        let initial = PoseReplayInitialState(phase: .standing, pendingFrames: 0,
                                             selectedLeg: .right, smoothedAngle: 180)
        let result = try f.replay(initial: initial)
        XCTAssertEqual(result.baseline.depthSamples[7].selectedLeg, .left)
        XCTAssertEqual(result.baseline.countedAtSeconds, [])
        XCTAssertEqual(result.countedAtSeconds, [1.4])
    }

    func testReliableSelectedLegFailsDepthWhileOppositeLegCompletesTwoDistinctCycles() throws {
        var f = Trace()
        f.add(.up, .up, 5)
        for _ in 0..<2 {
            f.add(.projected, .deep, 4)
            f.add(.up, .up, 3)
        }
        let result = try f.replay()
        XCTAssertTrue(result.baseline.depthSamples.allSatisfy { $0.selectedLeg == .left })
        XCTAssertEqual(result.baseline.countedAtSeconds, [])
        XCTAssertEqual(result.countedAtSeconds, [1.1, 1.8])
        let score = try PoseReplayRunner.score(
            PoseReplayResult(countedAtSeconds: result.countedAtSeconds, depthSamples: []),
            against: [PoseReplayAnnotation(startSeconds: 0, endSeconds: 1.2, isFullSquat: true),
                      PoseReplayAnnotation(startSeconds: 1.2, endSeconds: 2, isFullSquat: true)]
        )
        XCTAssertEqual([score.truePositives, score.falsePositives, score.falseNegatives], [2, 0, 0])
    }

    func testSelectedAnglePassesWhileOnlyProjectedThighHeightFails() throws {
        var f = Trace()
        f.add(.up, .up, 5)
        f.add(.heightGateOnly, .deep, 4)
        f.add(.up, .up, 8)
        let result = try f.replay()
        let sample = result.baseline.depthSamples[6]
        XCTAssertLessThanOrEqual(try XCTUnwrap(sample.kneeAngle), 105)
        XCTAssertGreaterThan(try XCTUnwrap(sample.normalizedThighHeight), 0.35)
        XCTAssertEqual(sample.selectedLeg, .left)
        XCTAssertEqual(result.baseline.countedAtSeconds, [])
        XCTAssertEqual(result.countedAtSeconds, [1.1])
    }

    func testOneSidedDropoutTimeoutOnReacquisitionAndFreshCycleAfterTimeout() throws {
        for (missingFrames, expectedFirst) in [(7, 1), (8, 0)] {
            var f = Trace()
            f.add(.up, .up, 5)
            f.add(.deep, .projected, 2)
            f.add(.hiddenHip, .projected, missingFrames)
            f.add(.deep, .projected, 1)
            f.add(.up, .up, 8)
            XCTAssertEqual(try f.replay().countedAtSeconds.count, expectedFirst)
            f.add(.deep, .projected, 5) // Now the sticky selected leg is right.
            f.add(.up, .up, 8)
            XCTAssertEqual(try f.replay().supplementalAtSeconds.count, expectedFirst + 1)
        }
    }

    func testBaselineAndShadowEvidenceForSameReturnCountOnlyOnce() throws {
        var f = Trace()
        f.add(.up, .up, 6)
        f.add(.projected, .deep, 3) // Opposite leg satisfies the experiment first.
        f.add(.deep, .deep, 9)
        f.add(.up, .projected, 6)  // Baseline counts before the bilateral return.
        f.add(.up, .up, 10)
        let result = try f.replay()
        XCTAssertEqual(result.baseline.countedAtSeconds.count, 1)
        XCTAssertEqual(result.countedAtSeconds, result.baseline.countedAtSeconds)
        XCTAssertEqual(result.supplementalAtSeconds, [])
    }

    func testSupplementWaitsForBaselineWhenSmoothingDelaysItsReturn() throws {
        var f = Trace()
        f.add(.up, .up, 5)
        f.add(.projected, .deep, 3)
        f.add(.deep, .deep, 10)
        f.add(.up, .up, 12)
        let result = try f.replay()
        XCTAssertEqual(result.baseline.depthSamples[20].phase, .lowered) // Third raw upright frame.
        XCTAssertEqual(result.baseline.countedAtSeconds.count, 1)
        XCTAssertEqual(result.countedAtSeconds, result.baseline.countedAtSeconds)
        XCTAssertEqual(result.supplementalAtSeconds, [])
    }

    func testOneFrameBeforeOcclusionOrEvidenceSplitAcrossLegsCannotConfirmDepth() throws {
        var f = Trace()
        f.add(.up, .up, 5)
        f.add(.deep, .projected, 1)
        f.add(.hiddenHip, .projected, 2)
        f.add(.deep, .projected, 2)
        f.add(.projected, .deep, 1)
        f.add(.up, .up, 8)
        XCTAssertEqual(try f.replay().countedAtSeconds, [])
    }

    func testMissingWitnessLongOcclusionAndStandingWitnessDiscardPendingAndLowered() throws {
        for depthFrames in [2, 10] {
            for (during, other, frames) in [(Leg.hiddenHip, Leg.projected, 9),
                                            (.hiddenHip, .up, 3), (.hiddenHip, .hiddenHip, 3)] {
                var f = Trace()
                f.add(.up, .up, 5)
                f.add(.deep, .projected, depthFrames)
                f.add(during, other, frames)
                f.add(.deep, .projected, 1)
                f.add(.up, .up, 10)
                XCTAssertEqual(try f.replay().countedAtSeconds, [])
            }
        }
    }

    func testPartialStepTurnAndOneLegBendProduceNoAdditionalCount() throws {
        for (l, r) in [(Leg.projected, Leg.projected), (.up, .deep),
                       (.projected, .steppingDeep), (.projected, .turningDeep)] {
            var f = Trace()
            f.add(.up, .up, 5)
            f.add(l, r, 8)
            f.add(.up, .up, 10)
            XCTAssertEqual(try f.replay().countedAtSeconds, [])
        }
    }

    func testModerateOppositeDescentOrSingleStrongFrameCannotQualifyPerspective() throws {
        var f = Trace()
        f.add(.up, .up, 5)
        f.add(.moderate, .deep, 3)
        f.add(.projected, .deep, 1)
        f.add(.moderate, .deep, 3)
        f.add(.up, .up, 8)
        XCTAssertEqual(try f.replay().countedAtSeconds, [])
    }

    func testVisibleAnkleStepOrDegenerateTriadWhileHipIsObscuredDiscardsEvidence() throws {
        for interruption in [Leg.hiddenMovingFoot, Leg.degenerate] {
            var f = Trace()
            f.add(.up, .up, 5)
            f.add(.deep, .projected, 2)
            f.add(interruption, .projected, 1)
            f.add(.deep, .projected, 1)
            f.add(.up, .up, 10)
            XCTAssertEqual(try f.replay().countedAtSeconds, [])
        }
    }

    func testNoRecoveryAcrossResetPoseGapDuplicateTimeOrOrientationChange() throws {
        for interruption in 0..<6 {
            var f = Trace()
            f.add(.up, .up, 5)
            f.add(.projected, .deep, 4)
            switch interruption {
            case 0: f.events.append(PoseReplayEvent(seconds: f.time, kind: .reset, pose: nil))
            case 1: f.tick += 3
            case 2: f.tick -= 1
            case 3: f.add(.up, .up, 1, rotation: 0)
            case 4: f.add(.up, .up, 1, aspect: 0.75)
            default: f.events.append(PoseReplayEvent(seconds: f.time, kind: .pose, pose: nil))
            }
            f.add(.up, .up, 12)
            XCTAssertEqual(try f.replay().countedAtSeconds, [])
        }
    }

    // Two real owner-side depth observations, then a switch with moderate corroboration.
    private func pendingSwitch() -> Trace {
        var f = Trace()
        f.add(.up, .up, 5)
        f.add(.deep, .moderate, 2)
        f.add(.hiddenHip, .justBelowWitnessThreshold, 1)
        return f
    }

    func testDelayedWitnessRecoversOnlyAfterFreshDepthAndStanding() throws {
        var f = pendingSwitch()
        f.add(.hiddenHip, .projected, 2)
        f.add(.deep, .projected, 1)
        XCTAssertEqual(try f.replay().countedAtSeconds, [])
        f.add(.up, .up, 12)
        let result = try f.replay()
        XCTAssertEqual(result.baseline.countedAtSeconds, [])
        XCTAssertEqual(result.supplementalAtSeconds, [1.3])
        XCTAssertEqual(result.countedAtSeconds, [1.3])
    }

    func testDelayedWitnessRejectsInsufficientOrInterruptedSupport() throws {
        for support in [[Leg.projected], [.projected, .moderate, .projected],
                        [.up, .projected, .projected]] {
            var f = pendingSwitch()
            for other in support { f.add(.hiddenHip, other, 1) }
            f.add(.deep, .projected, 1)
            f.add(.up, .up, 12)
            XCTAssertEqual(try f.replay().countedAtSeconds, [])
        }
    }

    func testDelayedWitnessYieldsToBaselineCountingTheSameExcursion() throws {
        var f = pendingSwitch()
        f.add(.hiddenHip, .projected, 2)
        f.add(.deep, .projected, 1)
        f.add(.deep, .up, 12) // The selected right leg rearms before the bilateral return.
        f.add(.deep, .deep, 12)
        f.add(.up, .up, 12)
        let result = try f.replay()
        XCTAssertEqual(result.baseline.countedAtSeconds.count, 1)
        XCTAssertEqual(result.countedAtSeconds, result.baseline.countedAtSeconds)
        XCTAssertEqual(result.supplementalAtSeconds, [])
    }

    func testDelayedWitnessExpiresFromLastReliableOwnerDepth() throws {
        var f = pendingSwitch()
        f.add(.hiddenHip, .projected, 4)
        f.add(.deep, .projected, 1)
        f.add(.up, .up, 12)
        XCTAssertEqual(try f.replay().countedAtSeconds, [])
    }

    func testDelayedWitnessRejectsShallowReturnStepTurnAndLostSupport() throws {
        for (owner, other) in [(Leg.moderate, Leg.projected), (.steppingDeep, .projected),
                               (.turningDeep, .projected), (.deep, .moderate)] {
            var f = pendingSwitch()
            f.add(.hiddenHip, .projected, 2)
            f.add(owner, other, 1)
            f.add(.up, .up, 12)
            XCTAssertEqual(try f.replay().countedAtSeconds, [])
        }
    }

    func testWarmLoweredV2PreservesBaselineWithoutFabricatingSupplementalCycle() throws {
        var f = Trace()
        f.add(.up, .up, 12)
        let state = PoseReplayInitialState(phase: .lowered, pendingFrames: 0,
                                           selectedLeg: .left, smoothedAngle: 90)
        let result = try f.replay(initial: state)
        XCTAssertEqual(result.baseline.countedAtSeconds.count, 1)
        XCTAssertEqual(result.countedAtSeconds, result.baseline.countedAtSeconds)
        XCTAssertEqual(result.supplementalAtSeconds, [])
    }
}

private enum Leg {
    case up, deep, projected, moderate, justBelowWitnessThreshold, heightGateOnly, hiddenHip, missingHip, hiddenMovingFoot, degenerate, steppingDeep, turningDeep

    func points(at x: Double) -> [JointPoint] {
        let hip: CGPoint
        let knee: CGPoint
        var ankle = CGPoint(x: x, y: 0.20)
        switch self {
        case .up:
            hip = CGPoint(x: x, y: 0.80)
            knee = CGPoint(x: x, y: 0.50)
        case .projected, .moderate:
            hip = CGPoint(x: x, y: self == .moderate ? 0.58 : 0.50)
            knee = CGPoint(x: x + 0.06, y: 0.40)
        case .justBelowWitnessThreshold:
            hip = CGPoint(x: x, y: 0.20 + 0.60 * (1 - 0.43893))
            knee = CGPoint(x: x + 0.06, y: 0.40)
        case .heightGateOnly:
            hip = CGPoint(x: x, y: 0.465)
            knee = CGPoint(x: x + 0.11, y: 0.37)
        case .degenerate:
            hip = ankle
            knee = ankle
        case .deep, .hiddenHip, .missingHip, .hiddenMovingFoot, .steppingDeep, .turningDeep:
            let offset = self == .steppingDeep || self == .turningDeep ? 0.17 : 0
            hip = CGPoint(x: x + offset, y: 0.47)
            knee = CGPoint(x: x + offset + 0.10, y: 0.445)
            if self == .steppingDeep || self == .hiddenMovingFoot { ankle.x += 0.17 }
        }
        return [JointPoint(location: hip, confidence: (self == .hiddenHip || self == .hiddenMovingFoot) ? 0.49 : 1),
                JointPoint(location: knee, confidence: 1), JointPoint(location: ankle, confidence: 1)]
    }
}

private struct Trace {
    var events: [PoseReplayEvent] = []
    var tick = 0
    var time: Double { Double(tick) / 10 }

    mutating func add(_ left: Leg, _ right: Leg, _ count: Int,
                      rotation: CGFloat = 90, aspect: CGFloat = 1) {
        let labels: [BodyJoint] = [.leftHip, .leftKnee, .leftAnkle, .rightHip, .rightKnee, .rightAnkle]
        let points = left.points(at: 0.25) + right.points(at: 0.55)
        var joints = Dictionary(uniqueKeysWithValues: zip(labels, points))
        if left == .missingHip { joints.removeValue(forKey: .leftHip) }
        if right == .missingHip { joints.removeValue(forKey: .rightHip) }
        let pose = BodyPose(joints: joints, aspectRatio: aspect, rotationAngle: rotation)
        for _ in 0..<count {
            events.append(PoseReplayEvent(seconds: time, kind: .pose, pose: PoseReplayPose(from: pose)))
            tick += 1
        }
    }

    func replay(initial: PoseReplayInitialState? = nil) throws -> PoseReplayRecoveryResult {
        try PoseReplayOcclusionRecovery.replay(PoseReplaySession(
            schemaVersion: initial == nil ? 1 : 2, events: events, annotations: [], initialState: initial
        ))
    }
}
#endif
