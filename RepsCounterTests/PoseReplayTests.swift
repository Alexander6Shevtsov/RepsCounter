import CoreGraphics
import XCTest
@testable import RepsCounter

#if DEBUG
final class PoseReplayTests: XCTestCase {
    func testCapturedNumericObservationsReplayDeterministically() throws {
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 10))
        let standingPose = SquatPoseFixture.pose(leftAngle: 170)
        let loweredPose = SquatPoseFixture.pose(leftAngle: 90)
        var currentTime = 10.0

        for (pose, numberOfFrames) in [
            (standingPose, 24),
            (loweredPose, 24),
            (standingPose, 24)
        ] {
            for _ in 0..<numberOfFrames {
                currentTime += 0.08
                recorder.append(pose, at: currentTime)
            }
        }
        recorder.stop()
        XCTAssertEqual(recorder.eventCount, 72)

        let data = try recorder.encodedSession()
        let restoredSession = try JSONDecoder().decode(PoseReplaySession.self, from: data)
        XCTAssertEqual(restoredSession.schemaVersion, 1)
        XCTAssertEqual(restoredSession.events.count, 72)
        XCTAssertEqual(restoredSession.events.first?.pose?.points.count, 3)

        let firstRun = try PoseReplayRunner.replay(restoredSession)
        let secondRun = try PoseReplayRunner.replay(restoredSession)
        XCTAssertEqual(firstRun.countedAtSeconds.count, 1)
        XCTAssertEqual(firstRun.countedAtSeconds, secondRun.countedAtSeconds)
        XCTAssertEqual(firstRun.depthSamples.count, 72)
    }

    func testReplayPreservesSelectedLegAndJointConfidences() throws {
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        let sourcePose = SquatPoseFixture.pose(
            leftAngle: 170,
            rightAngle: 165,
            leftConfidence: 0.60,
            rightConfidence: 0.93
        )
        recorder.append(sourcePose, at: 0.08)
        recorder.stop()

        let data = try recorder.encodedSession()
        let session = try JSONDecoder().decode(PoseReplaySession.self, from: data)
        let restoredPose = try XCTUnwrap(session.events.first?.pose?.restore())
        let leftKneeConfidence = try XCTUnwrap(restoredPose.joints[.leftKnee]?.confidence)
        let rightKneeConfidence = try XCTUnwrap(restoredPose.joints[.rightKnee]?.confidence)
        XCTAssertEqual(leftKneeConfidence, 0.60, accuracy: 0.001)
        XCTAssertEqual(rightKneeConfidence, 0.93, accuracy: 0.001)

        let result = try PoseReplayRunner.replay(session)
        XCTAssertEqual(result.depthSamples.first?.selectedLeg, .right)
    }

    func testReplayResetPreventsCountingMovementAcrossSegments() throws {
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        let standingPose = SquatPoseFixture.pose(leftAngle: 170)
        let loweredPose = SquatPoseFixture.pose(leftAngle: 90)
        var currentTime = 0.0

        for _ in 0..<20 {
            currentTime += 0.08
            recorder.append(standingPose, at: currentTime)
        }
        for _ in 0..<20 {
            currentTime += 0.08
            recorder.append(loweredPose, at: currentTime)
        }
        currentTime += 0.02
        recorder.markReset(at: currentTime)
        for _ in 0..<20 {
            currentTime += 0.08
            recorder.append(standingPose, at: currentTime)
        }
        recorder.stop()

        let result = try PoseReplayRunner.replay(recorder.session)
        XCTAssertTrue(result.countedAtSeconds.isEmpty)
    }

    func testReplayGapPreventsJoiningTwoPoseSegments() throws {
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        let standingPose = SquatPoseFixture.pose(leftAngle: 170)
        let loweredPose = SquatPoseFixture.pose(leftAngle: 90)
        var timestamp = 0.0
        for _ in 0..<15 {
            timestamp += 0.08
            recorder.append(standingPose, at: timestamp)
        }
        for _ in 0..<15 {
            timestamp += 0.08
            recorder.append(loweredPose, at: timestamp)
        }
        timestamp += 0.40
        for _ in 0..<15 {
            timestamp += 0.08
            recorder.append(standingPose, at: timestamp)
        }
        recorder.stop()

        let result = try PoseReplayRunner.replay(recorder.session)
        XCTAssertTrue(result.countedAtSeconds.isEmpty)
    }

    func testScoringCountsFullPartialDuplicateAndUnlabelledEvents() throws {
        let result = PoseReplayResult(
            countedAtSeconds: [1.0, 1.5, 5.0, 7.0],
            depthSamples: []
        )
        let annotations = [
            PoseReplayAnnotation(startSeconds: 0, endSeconds: 2, isFullSquat: true),
            PoseReplayAnnotation(startSeconds: 2, endSeconds: 4, isFullSquat: true),
            PoseReplayAnnotation(startSeconds: 4, endSeconds: 6, isFullSquat: false)
        ]
        let score = try PoseReplayRunner.score(result, against: annotations)
        XCTAssertEqual(score.truePositives, 1)
        XCTAssertEqual(score.falseNegatives, 1)
        XCTAssertEqual(score.falsePositives, 3)
    }

    func testDepthShadowDistinguishesAboveAndBelowKneeWithoutChangingCounter() throws {
        let basePose = SquatPoseFixture.pose(leftAngle: 170)
        let slightlyAboveKnee = SquatPoseFixture.replacing(
            basePose,
            joint: .leftHip,
            location: CGPoint(x: 0.60, y: 0.52)
        )
        let belowKnee = SquatPoseFixture.replacing(
            basePose,
            joint: .leftHip,
            location: CGPoint(x: 0.60, y: 0.40)
        )
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        recorder.append(slightlyAboveKnee, at: 0.08)
        recorder.append(belowKnee, at: 0.16)
        recorder.stop()

        let result = try PoseReplayRunner.replay(recorder.session)
        XCTAssertEqual(result.depthSamples.count, 2)
        XCTAssertEqual(result.depthSamples[0].hipBelowKnee, false)
        XCTAssertEqual(result.depthSamples[1].hipBelowKnee, true)
        XCTAssertGreaterThan(result.depthSamples[0].signedHipKneeVerticalDistance ?? -1, 0)
        XCTAssertLessThan(result.depthSamples[1].signedHipKneeVerticalDistance ?? 1, 0)
        XCTAssertLessThan(result.depthSamples[0].normalizedThighHeight ?? 1, 0.35)
        XCTAssertTrue(result.countedAtSeconds.isEmpty)
    }

    func testBadReplayVersionAndTimelineAreRejected() {
        let badVersion = PoseReplaySession(schemaVersion: 5, events: [], annotations: [])
        XCTAssertThrowsError(try PoseReplayRunner.replay(badVersion))

        let outOfOrder = PoseReplaySession(
            schemaVersion: 1,
            events: [
                PoseReplayEvent(seconds: 0.20, kind: .pose, pose: nil),
                PoseReplayEvent(seconds: 0.10, kind: .pose, pose: nil)
            ],
            annotations: []
        )
        XCTAssertThrowsError(try PoseReplayRunner.replay(outOfOrder))
    }

    func testRecordingIsBoundedAndNeverStartsWithoutExplicitAction() throws {
        var recorder = PoseReplayRecorder()
        recorder.append(SquatPoseFixture.pose(), at: 0)
        XCTAssertEqual(recorder.eventCount, 0)
        XCTAssertTrue(recorder.start(at: 0))
        let standingPose = SquatPoseFixture.pose()
        for frameNumber in 0..<1230 {
            recorder.append(standingPose, at: Double(frameNumber) * 0.08)
        }
        XCTAssertEqual(recorder.eventCount, 1200)
        recorder.stop()
        recorder.append(standingPose, at: 100)
        XCTAssertEqual(recorder.eventCount, 1200)
        XCTAssertLessThan(try recorder.encodedSession().count, 2_000_000)
    }
}
#endif
