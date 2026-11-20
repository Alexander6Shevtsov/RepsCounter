import CoreGraphics
import XCTest
@testable import RepsCounter

#if DEBUG
final class ReplayGuardIntegrationTests: XCTestCase {
    func testSynchronizedSquatCountsOnceAcrossAllReplayVariants() throws {
        let comparison = try PoseReplayGuardIntegrationAudit.replay(completeSession())
        XCTAssertEqual(comparison.baselineCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.adaptiveCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.graceCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.asymmetricCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.guardedCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.mergedDuplicates, 1)
        XCTAssertEqual(comparison.rejectedLeftCandidates, 0)
        XCTAssertEqual(comparison.rejectedRightCandidates, 0)
    }

    func testFullFollowedByPartialCannotCreateExtraCounts() throws {
        let session = recordedSession([
            (170, 170, 20), (90, 90, 20), (170, 170, 20),
            (120, 120, 20), (170, 170, 20)
        ])
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)
        XCTAssertEqual(comparison.baselineCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.graceCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.asymmetricCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.guardedCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.mergedDuplicates, 1)
    }

    func testGuardRejectsContradictoryLeftCandidate() throws {
        let session = recordedSession([
            (170, 170, 20), (90, 120, 20), (170, 170, 20)
        ])
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)
        XCTAssertTrue(comparison.guardedCountedAtSeconds.isEmpty)
        XCTAssertEqual(comparison.rejectedLeftCandidates, 1)
        XCTAssertEqual(comparison.rejectedRightCandidates, 0)
    }

    func testGuardRejectsContradictoryRightCandidate() throws {
        let session = recordedSession([
            (170, 170, 20), (120, 90, 20), (170, 170, 20)
        ])
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)
        XCTAssertTrue(comparison.guardedCountedAtSeconds.isEmpty)
        XCTAssertEqual(comparison.rejectedLeftCandidates, 0)
        XCTAssertEqual(comparison.rejectedRightCandidates, 1)
    }

    func testUnreliableOppositeLegKeepsSingleLegFallback() throws {
        let session = recordedSession([
            (170, 170, 20), (90, 120, 20), (170, 170, 20)
        ], rightConfidence: 0.49)
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)
        XCTAssertEqual(comparison.guardedCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.rejectedLeftCandidates, 0)
        XCTAssertEqual(comparison.rejectedRightCandidates, 0)
    }

    func testSingleMissingFramePreservesGuardAndGrace() throws {
        var session = completeSession()
        replaceWithMissingPose(&session, at: [40])
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)
        XCTAssertEqual(comparison.guardedCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.graceCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.mergedDuplicates, 1)
    }

    func testSustainedMissingFramesCannotCompleteInterruptedSquat() throws {
        var session = completeSession()
        replaceWithMissingPose(&session, at: [40, 41, 42, 43])
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)
        XCTAssertTrue(comparison.guardedCountedAtSeconds.isEmpty)
        XCTAssertTrue(comparison.graceCountedAtSeconds.isEmpty)
    }

    func testExplicitResetDoesNotJoinSeparateSquatPhases() throws {
        var session = completeSession()
        let resetIndex = 40
        session.events[resetIndex] = PoseReplayEvent(
            seconds: session.events[resetIndex].seconds,
            kind: .reset,
            pose: nil
        )
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)
        XCTAssertTrue(comparison.guardedCountedAtSeconds.isEmpty)
        XCTAssertTrue(comparison.graceCountedAtSeconds.isEmpty)
    }

    func testObservationGapDoesNotProduceDelayedCount() throws {
        var session = completeSession()
        for frameIndex in 40..<session.events.count {
            let event = session.events[frameIndex]
            session.events[frameIndex] = PoseReplayEvent(
                seconds: event.seconds + 0.40,
                kind: event.kind,
                pose: event.pose
            )
        }
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)
        XCTAssertTrue(comparison.guardedCountedAtSeconds.isEmpty)
        XCTAssertTrue(comparison.graceCountedAtSeconds.isEmpty)
    }

    func testFastRepeatedSquatsCountExactlyTwice() throws {
        let session = recordedSession([
            (170, 170, 16), (90, 90, 16), (170, 170, 16),
            (90, 90, 16), (170, 170, 16)
        ], frameInterval: 0.06)
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)
        XCTAssertEqual(comparison.guardedCountedAtSeconds.count, 2)
        XCTAssertEqual(comparison.mergedDuplicates, 2)
        XCTAssertEqual(comparison.rejectedLeftCandidates, 0)
        XCTAssertEqual(comparison.rejectedRightCandidates, 0)
    }

    func testPendingEventsAreCommittedOnceAtReplayEnd() throws {
        let session = recordedSession([
            (170, 170, 20), (90, 90, 20), (170, 170, 6)
        ])
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)
        XCTAssertEqual(comparison.guardedCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.mergedDuplicates, 1)
    }

    func testGuardResultsCanBeScoredWithoutUsingCommitDelay() throws {
        var session = recordedSession([
            (170, 170, 20), (90, 90, 20), (170, 170, 20),
            (120, 120, 20), (170, 170, 20)
        ])
        session.annotations = [
            PoseReplayAnnotation(
                startSeconds: 0,
                endSeconds: 4.80,
                isFullSquat: true
            ),
            PoseReplayAnnotation(
                startSeconds: 4.80,
                endSeconds: 8.10,
                isFullSquat: false
            )
        ]
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)
        let events = PoseReplayResult(
            countedAtSeconds: comparison.guardedCountedAtSeconds,
            depthSamples: []
        )
        let score = try PoseReplayRunner.score(events, against: session.annotations)
        XCTAssertEqual(score.truePositives, 1)
        XCTAssertEqual(score.falsePositives, 0)
        XCTAssertEqual(score.falseNegatives, 0)
    }

    func testProjectionGuardRecoversPerspectiveConflictWithoutChangingStrictGuard() throws {
        let session = projectedSession(oppositeBent: false, restrictedDescent: false)
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)

        XCTAssertTrue(comparison.guardedCountedAtSeconds.isEmpty)
        XCTAssertEqual(comparison.rejectedLeftCandidates, 1)
        XCTAssertEqual(comparison.projectionGuardedCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.projectionRejectedLeftCandidates, 0)
    }

    func testProjectionGuardKeepsConflictWhenOppositeKneeAlsoBends() throws {
        let session = projectedSession(oppositeBent: true, restrictedDescent: false)
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)

        XCTAssertTrue(comparison.guardedCountedAtSeconds.isEmpty)
        XCTAssertTrue(comparison.projectionGuardedCountedAtSeconds.isEmpty)
        XCTAssertEqual(comparison.rejectedLeftCandidates, 1)
        XCTAssertEqual(comparison.projectionRejectedLeftCandidates, 1)
    }

    func testProjectionGuardNeedsCalibratedHipDescent() throws {
        let session = projectedSession(oppositeBent: false, restrictedDescent: true)
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)

        XCTAssertTrue(comparison.guardedCountedAtSeconds.isEmpty)
        XCTAssertTrue(comparison.projectionGuardedCountedAtSeconds.isEmpty)
        XCTAssertEqual(comparison.rejectedLeftCandidates, 1)
        XCTAssertEqual(comparison.projectionRejectedLeftCandidates, 1)
    }

    func testProjectionGuardDoesNotDoubleCountBothReliableLegs() throws {
        let comparison = try PoseReplayGuardIntegrationAudit.replay(completeSession())

        XCTAssertEqual(comparison.guardedCountedAtSeconds.count, 1)
        XCTAssertEqual(comparison.projectionGuardedCountedAtSeconds.count, 1)
    }

    func testProjectionGuardCannotJoinLoweredPhaseAcrossReset() throws {
        var session = projectedSession(oppositeBent: false, restrictedDescent: false)
        session.events[40] = PoseReplayEvent(
            seconds: session.events[40].seconds,
            kind: .reset,
            pose: nil
        )
        let comparison = try PoseReplayGuardIntegrationAudit.replay(session)

        XCTAssertTrue(comparison.guardedCountedAtSeconds.isEmpty)
        XCTAssertTrue(comparison.projectionGuardedCountedAtSeconds.isEmpty)
    }

    private func projectedSession(
        oppositeBent: Bool,
        restrictedDescent: Bool
    ) -> PoseReplaySession {
        let standingPose = projectedPose(
            lowered: false,
            oppositeBent: false,
            restrictedDescent: false
        )
        let loweredPose = projectedPose(
            lowered: true,
            oppositeBent: oppositeBent,
            restrictedDescent: restrictedDescent
        )
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        var currentTime: TimeInterval = 0
        for (pose, frameCount) in [
            (standingPose, 20),
            (loweredPose, 20),
            (standingPose, 20)
        ] {
            for _ in 0..<frameCount {
                currentTime += 0.08
                recorder.append(pose, at: currentTime)
            }
        }
        recorder.stop()
        return recorder.session
    }

    private func projectedPose(
        lowered: Bool,
        oppositeBent: Bool,
        restrictedDescent: Bool
    ) -> BodyPose {
        let leftHip = lowered
            ? CGPoint(x: 0.48, y: 0.47) : CGPoint(x: 0.35, y: 0.80)
        let leftKnee = CGPoint(x: 0.35, y: lowered ? 0.445 : 0.50)
        let leftAnkle = lowered
            ? CGPoint(x: 0.40, y: restrictedDescent ? 0.07 : 0.25)
            : CGPoint(x: 0.35, y: 0.20)
        let rightAnkle = lowered && oppositeBent
            ? CGPoint(x: 0.82, y: 0.43)
            : CGPoint(x: 0.65, y: 0.20)
        let points: [BodyJoint: JointPoint] = [
            .leftHip: JointPoint(location: leftHip, confidence: 0.93),
            .leftKnee: JointPoint(location: leftKnee, confidence: 0.93),
            .leftAnkle: JointPoint(location: leftAnkle, confidence: 0.93),
            .rightHip: JointPoint(
                location: CGPoint(x: 0.65, y: 0.80), confidence: 0.93
            ),
            .rightKnee: JointPoint(
                location: CGPoint(x: 0.65, y: 0.50), confidence: 0.93
            ),
            .rightAnkle: JointPoint(location: rightAnkle, confidence: 0.93)
        ]
        return BodyPose(joints: points, aspectRatio: 1, rotationAngle: 90)
    }

    private func completeSession() -> PoseReplaySession {
        recordedSession([
            (170, 170, 20), (90, 90, 20), (170, 170, 20)
        ])
    }

    private func replaceWithMissingPose(
        _ session: inout PoseReplaySession,
        at frameIndices: [Int]
    ) {
        for frameIndex in frameIndices {
            let previous = session.events[frameIndex]
            session.events[frameIndex] = PoseReplayEvent(
                seconds: previous.seconds,
                kind: .pose,
                pose: nil
            )
        }
    }

    private func recordedSession(
        _ phases: [(leftAngle: Double, rightAngle: Double, frameCount: Int)],
        leftConfidence: Float = 0.93,
        rightConfidence: Float = 0.93,
        frameInterval: TimeInterval = 0.08
    ) -> PoseReplaySession {
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        var currentTime: TimeInterval = 0
        for phase in phases {
            let pose = SquatPoseFixture.pose(
                leftAngle: phase.leftAngle,
                rightAngle: phase.rightAngle,
                leftConfidence: leftConfidence,
                rightConfidence: rightConfidence
            )
            for _ in 0..<phase.frameCount {
                currentTime += frameInterval
                recorder.append(pose, at: currentTime)
            }
        }
        recorder.stop()
        return recorder.session
    }
}
#endif
