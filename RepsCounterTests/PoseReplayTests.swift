import CoreGraphics
import XCTest
@testable import RepsCounter

#if DEBUG
final class PoseReplayTests: XCTestCase {
    @MainActor
    func testReplayFromActualWorkoutViewModelMatchesProductionCount() throws {
        let clock = PoseReplayClock()
        let store = PoseReplayStore()
        let viewModel = WorkoutViewModel(persistence: store, timeSource: clock)
        defer { viewModel.finish() }
        XCTAssertFalse(viewModel.isPoseReplayRecording)
        XCTAssertTrue(viewModel.startPoseReplayRecording())

        let standingPose = SquatPoseFixture.pose(leftAngle: 170)
        let loweredPose = SquatPoseFixture.pose(leftAngle: 90)
        for (pose, numberOfFrames) in [
            (standingPose, 24),
            (loweredPose, 24),
            (standingPose, 24)
        ] {
            for _ in 0..<numberOfFrames {
                clock.currentTime += 0.08
                viewModel.process(pose)
            }
        }
        XCTAssertEqual(viewModel.poseReplayEventCount, 72)
        let data = try XCTUnwrap(viewModel.stopPoseReplayRecording())
        XCTAssertFalse(viewModel.isPoseReplayRecording)
        let session = try JSONDecoder().decode(PoseReplaySession.self, from: data)
        let replayed = try PoseReplayRunner.replay(session)
        XCTAssertEqual(replayed.countedAtSeconds.count, 1)
        XCTAssertEqual(viewModel.latestDiagnostics?.phase, .standing)
        XCTAssertEqual(viewModel.latestDiagnostics?.recentDepthAttempts.last?.outcome, .counted)
    }

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

    func testUnannotatedRecordingCannotClaimAccuracy() {
        let result = PoseReplayResult(countedAtSeconds: [1.0], depthSamples: [])
        XCTAssertThrowsError(try PoseReplayRunner.score(result, against: []))
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

    func testBilateralShadowMergesBothLegsForOneRealMovement() throws {
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        var timestamp = 0.0
        for (angle, frames) in [(170.0, 20), (90.0, 20), (170.0, 20)] {
            for _ in 0..<frames {
                timestamp += 0.08
                recorder.append(
                    SquatPoseFixture.pose(leftAngle: angle, rightAngle: angle),
                    at: timestamp
                )
            }
        }
        recorder.stop()

        let firstRun = try PoseReplayBilateralRunner.replay(recorder.session)
        let secondRun = try PoseReplayBilateralRunner.replay(recorder.session)
        XCTAssertEqual(firstRun.baselineCountedAtSeconds.count, 1)
        XCTAssertEqual(firstRun.leftCountedAtSeconds.count, 1)
        XCTAssertEqual(firstRun.rightCountedAtSeconds.count, 1)
        XCTAssertEqual(firstRun.countedAtSeconds.count, 1)
        XCTAssertEqual(firstRun.mergedDuplicateEvents, 1)
        XCTAssertEqual(firstRun.combinedEvents.first?.contributingLegs.count, 2)
        XCTAssertEqual(firstRun.countedAtSeconds, secondRun.countedAtSeconds)
    }

    func testBilateralShadowFindsSeparateRepetitionsOnDifferentReliableLegs() throws {
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        var timestamp = 0.0
        let cycles: [(leftConfidence: Float, rightConfidence: Float)] = [
            (0.49, 0.93),
            (0.94, 0.49)
        ]
        for (leftConfidence, rightConfidence) in cycles {
            for (angle, frames) in [(170.0, 20), (90.0, 20), (170.0, 20)] {
                for _ in 0..<frames {
                    timestamp += 0.08
                    recorder.append(
                        SquatPoseFixture.pose(
                            leftAngle: angle,
                            rightAngle: angle,
                            leftConfidence: leftConfidence,
                            rightConfidence: rightConfidence
                        ),
                        at: timestamp
                    )
                }
            }
        }
        recorder.stop()

        let result = try PoseReplayBilateralRunner.replay(recorder.session)
        XCTAssertEqual(result.leftCountedAtSeconds.count, 1)
        XCTAssertEqual(result.rightCountedAtSeconds.count, 1)
        XCTAssertEqual(result.countedAtSeconds.count, 2)
        XCTAssertEqual(result.mergedDuplicateEvents, 0)
        XCTAssertEqual(result.combinedEvents[0].contributingLegs, [.right])
        XCTAssertEqual(result.combinedEvents[1].contributingLegs, [.left])
    }

    func testBilateralShadowDoesNotCreateSecondEventFromPartialOppositeLeg() throws {
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        var timestamp = 0.0
        for (leftAngle, rightAngle, frames) in [
            (170.0, 170.0, 20),
            (120.0, 90.0, 20),
            (170.0, 170.0, 20)
        ] {
            for _ in 0..<frames {
                timestamp += 0.08
                recorder.append(
                    SquatPoseFixture.pose(
                        leftAngle: leftAngle, rightAngle: rightAngle
                    ),
                    at: timestamp
                )
            }
        }
        recorder.stop()

        let result = try PoseReplayBilateralRunner.replay(recorder.session)
        XCTAssertTrue(result.leftCountedAtSeconds.isEmpty)
        XCTAssertEqual(result.rightCountedAtSeconds.count, 1)
        XCTAssertEqual(result.countedAtSeconds.count, 1)
        XCTAssertEqual(result.combinedEvents.first?.contributingLegs, [.right])
    }

    func testBilateralShadowResetsBothLegsAcrossTrackingInterruption() throws {
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        var timestamp = 0.0
        for _ in 0..<20 {
            timestamp += 0.08
            recorder.append(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170), at: timestamp)
        }
        for _ in 0..<20 {
            timestamp += 0.08
            recorder.append(SquatPoseFixture.pose(leftAngle: 90, rightAngle: 90), at: timestamp)
        }
        timestamp += 0.02
        recorder.markReset(at: timestamp)
        for _ in 0..<20 {
            timestamp += 0.08
            recorder.append(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170), at: timestamp)
        }
        recorder.stop()

        let result = try PoseReplayBilateralRunner.replay(recorder.session)
        XCTAssertTrue(result.countedAtSeconds.isEmpty)
        XCTAssertTrue(result.leftCountedAtSeconds.isEmpty)
        XCTAssertTrue(result.rightCountedAtSeconds.isEmpty)
    }

    func testBilateralShadowGapCannotFinishPriorSquat() throws {
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        var timestamp = 0.0
        for _ in 0..<20 {
            timestamp += 0.08
            recorder.append(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170), at: timestamp)
        }
        for _ in 0..<20 {
            timestamp += 0.08
            recorder.append(SquatPoseFixture.pose(leftAngle: 90, rightAngle: 90), at: timestamp)
        }
        timestamp += 0.40
        for _ in 0..<20 {
            timestamp += 0.08
            recorder.append(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170), at: timestamp)
        }
        recorder.stop()

        let result = try PoseReplayBilateralRunner.replay(recorder.session)
        XCTAssertTrue(result.countedAtSeconds.isEmpty)
        XCTAssertEqual(result.mergedDuplicateEvents, 0)
    }

    func testBilateralShadowCanBeScoredOnlyWithManualAnnotations() throws {
        var recorder = PoseReplayRecorder()
        XCTAssertTrue(recorder.start(at: 0))
        var timestamp = 0.0
        for (angle, frames) in [(170.0, 20), (90.0, 20), (170.0, 20)] {
            for _ in 0..<frames {
                timestamp += 0.08
                recorder.append(
                    SquatPoseFixture.pose(leftAngle: angle, rightAngle: angle),
                    at: timestamp
                )
            }
        }
        recorder.stop()
        let shadow = try PoseReplayBilateralRunner.replay(recorder.session)
        let result = PoseReplayResult(
            countedAtSeconds: shadow.countedAtSeconds,
            depthSamples: []
        )
        XCTAssertThrowsError(try PoseReplayRunner.score(result, against: []))
        let annotations = [
            PoseReplayAnnotation(startSeconds: 0, endSeconds: 5, isFullSquat: true)
        ]
        let score = try PoseReplayRunner.score(result, against: annotations)
        XCTAssertEqual(score.truePositives, 1)
        XCTAssertEqual(score.falsePositives, 0)
        XCTAssertEqual(score.falseNegatives, 0)
    }

    func testBilateralFusionDoesNotMergeDistinctQuickRepetitions() {
        let candidates = [
            PoseReplayLegCount(
                leg: .right, countedAtSeconds: 5.0, loweredAtSeconds: 4.0
            ),
            PoseReplayLegCount(
                leg: .left, countedAtSeconds: 5.4, loweredAtSeconds: 5.1
            )
        ]
        let combined = PoseReplayBilateralRunner.mergeMatchingMovements(candidates)
        XCTAssertEqual(combined.count, 2)
        XCTAssertEqual(combined[0].contributingLegs, [.right])
        XCTAssertEqual(combined[1].contributingLegs, [.left])
    }

    func testBilateralFusionMergesStaggeredObservationsOfSameRepetition() {
        let candidates = [
            PoseReplayLegCount(
                leg: .right, countedAtSeconds: 5.0, loweredAtSeconds: 4.0
            ),
            PoseReplayLegCount(
                leg: .left, countedAtSeconds: 5.4, loweredAtSeconds: 4.25
            )
        ]
        let combined = PoseReplayBilateralRunner.mergeMatchingMovements(candidates)
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(combined.first?.contributingLegs, [.right, .left])
        XCTAssertEqual(combined.first?.countedAtSeconds ?? 0, 5.0, accuracy: 0.001)
    }

    func testBilateralFusionNeverMergesTwoCountsFromSameLeg() {
        let candidates = [
            PoseReplayLegCount(
                leg: .left, countedAtSeconds: 5.0, loweredAtSeconds: 4.0
            ),
            PoseReplayLegCount(
                leg: .left, countedAtSeconds: 5.5, loweredAtSeconds: 4.5
            )
        ]
        let combined = PoseReplayBilateralRunner.mergeMatchingMovements(candidates)
        XCTAssertEqual(combined.count, 2)
    }


    func testDepthAuditSeparatesSyntheticFullAndShallowKneeBends() throws {
        let fullPose = depthAuditPose(
            hipPosition: CGPoint(x: 0.30, y: 0.54),
            kneePosition: CGPoint(x: 0.50, y: 0.50),
            anklePosition: CGPoint(x: 0.50, y: 0.20)
        )
        let shallowPose = depthAuditPose(
            hipPosition: CGPoint(x: 0.40, y: 0.62),
            kneePosition: CGPoint(x: 0.55, y: 0.50),
            anklePosition: CGPoint(x: 0.40, y: 0.30)
        )
        let replayEvents = [
            0.10, 0.20, 0.30, 0.40
        ].map { timestamp in
            PoseReplayEvent(
                seconds: timestamp,
                kind: .pose,
                pose: PoseReplayPose(from: fullPose)
            )
        } + [1.10, 1.20, 1.30, 1.40].map { timestamp in
            PoseReplayEvent(
                seconds: timestamp,
                kind: .pose,
                pose: PoseReplayPose(from: shallowPose)
            )
        }
        let session = PoseReplaySession(
            schemaVersion: 1,
            events: replayEvents,
            annotations: [
                PoseReplayAnnotation(startSeconds: 0, endSeconds: 1, isFullSquat: true),
                PoseReplayAnnotation(startSeconds: 1, endSeconds: 2, isFullSquat: false)
            ]
        )
        let baseline = try PoseReplayRunner.replay(session)
        let report = try PoseReplayDepthAudit.evaluate(session)
        let subsequentReplay = try PoseReplayRunner.replay(session)
        XCTAssertEqual(baseline.countedAtSeconds, subsequentReplay.countedAtSeconds)
        XCTAssertEqual(report.attempts.count, 2)

        let angleOnly = report.score(for: .kneeOnly)
        XCTAssertEqual(angleOnly.fullSatisfied, 1)
        XCTAssertEqual(angleOnly.partialAccepted, 1)

        let projected = report.score(for: .legacyProjected)
        XCTAssertEqual(projected.fullSatisfied, 1)
        XCTAssertEqual(projected.fullMissed, 0)
        XCTAssertEqual(projected.partialAccepted, 0)
        XCTAssertEqual(projected.partialRejected, 1)

        let strictHeight = report.score(for: .hipCenterBelowKnee)
        XCTAssertEqual(strictHeight.fullMissed, 1)
        XCTAssertEqual(strictHeight.partialAccepted, 0)
    }

    func testDepthAuditRequiresThreeReliableConsecutiveSamples() throws {
        let unreliablePose = depthAuditPose(
            hipPosition: CGPoint(x: 0.30, y: 0.54),
            kneePosition: CGPoint(x: 0.50, y: 0.50),
            anklePosition: CGPoint(x: 0.50, y: 0.20),
            kneeConfidence: 0.49
        )
        let replayEvents = [0.10, 0.20, 0.30, 0.40].map { timestamp in
            PoseReplayEvent(
                seconds: timestamp,
                kind: .pose,
                pose: PoseReplayPose(from: unreliablePose)
            )
        }
        let session = PoseReplaySession(
            schemaVersion: 1,
            events: replayEvents,
            annotations: [
                PoseReplayAnnotation(startSeconds: 0, endSeconds: 1, isFullSquat: true)
            ]
        )
        let report = try PoseReplayDepthAudit.evaluate(session)
        XCTAssertEqual(report.score(for: .kneeOnly).fullMissed, 1)
        XCTAssertEqual(report.score(for: .legacyProjected).fullMissed, 1)
        XCTAssertEqual(report.score(for: .hipCenterBelowKnee).fullMissed, 1)
    }

    func testDepthAuditDoesNotCountSamplesAcrossReset() throws {
        let fullPose = depthAuditPose(
            hipPosition: CGPoint(x: 0.30, y: 0.54),
            kneePosition: CGPoint(x: 0.50, y: 0.50),
            anklePosition: CGPoint(x: 0.50, y: 0.20)
        )
        let replayEvents: [PoseReplayEvent] = [
            PoseReplayEvent(seconds: 0.10, kind: .pose, pose: PoseReplayPose(from: fullPose)),
            PoseReplayEvent(seconds: 0.20, kind: .pose, pose: PoseReplayPose(from: fullPose)),
            PoseReplayEvent(seconds: 0.30, kind: .reset, pose: nil),
            PoseReplayEvent(seconds: 0.40, kind: .pose, pose: PoseReplayPose(from: fullPose))
        ]
        let session = PoseReplaySession(
            schemaVersion: 1,
            events: replayEvents,
            annotations: [
                PoseReplayAnnotation(startSeconds: 0, endSeconds: 1, isFullSquat: true)
            ]
        )
        let report = try PoseReplayDepthAudit.evaluate(session)
        XCTAssertEqual(report.score(for: .kneeOnly).fullMissed, 1)
        XCTAssertEqual(report.score(for: .legacyProjected).fullMissed, 1)
    }

    func testDepthAuditRejectsUnannotatedReplay() {
        let session = PoseReplaySession(schemaVersion: 1, events: [], annotations: [])
        XCTAssertThrowsError(try PoseReplayDepthAudit.evaluate(session))
    }

    func testAdaptiveShadowRecoversBilateralDepthWithoutChangingBaseline() throws {
        let session = adaptiveSession(
            standingFirst: true,
            bothLowered: true,
            legacyDepth: false
        )
        let original = try PoseReplayRunner.replay(session)
        let adaptive = try PoseReplayAdaptiveDepthAudit.replay(session)
        XCTAssertEqual(original.countedAtSeconds.count, 0)
        XCTAssertEqual(adaptive.countedAtSeconds.count, 1)
        XCTAssertGreaterThan(adaptive.assistedDepthFrames, 0)
        let replayed = try PoseReplayRunner.replay(session)
        XCTAssertEqual(replayed.countedAtSeconds, original.countedAtSeconds)
    }

    func testAdaptiveShadowRequiresReliableSecondLeg() throws {
        let session = adaptiveSession(
            standingFirst: true,
            bothLowered: true,
            legacyDepth: false,
            rightConfidence: 0.49
        )
        let adaptive = try PoseReplayAdaptiveDepthAudit.replay(session)
        XCTAssertEqual(adaptive.countedAtSeconds.count, 0)
        XCTAssertEqual(adaptive.assistedDepthFrames, 0)
    }

    func testAdaptiveShadowRejectsOneSidedKneeBend() throws {
        let session = adaptiveSession(
            standingFirst: true,
            bothLowered: false,
            legacyDepth: false
        )
        let adaptive = try PoseReplayAdaptiveDepthAudit.replay(session)
        XCTAssertEqual(adaptive.countedAtSeconds.count, 0)
        XCTAssertEqual(adaptive.assistedDepthFrames, 0)
    }

    func testAdaptiveShadowNeedsStandingCalibration() throws {
        let session = adaptiveSession(
            standingFirst: false,
            bothLowered: true,
            legacyDepth: false
        )
        let adaptive = try PoseReplayAdaptiveDepthAudit.replay(session)
        XCTAssertEqual(adaptive.countedAtSeconds.count, 0)
        XCTAssertEqual(adaptive.assistedDepthFrames, 0)
    }

    func testAdaptiveShadowPreservesAlreadyValidDepth() throws {
        let session = adaptiveSession(
            standingFirst: true,
            bothLowered: true,
            legacyDepth: true
        )
        let original = try PoseReplayRunner.replay(session)
        let adaptive = try PoseReplayAdaptiveDepthAudit.replay(session)
        XCTAssertEqual(original.countedAtSeconds.count, 1)
        XCTAssertEqual(adaptive.countedAtSeconds.count, 1)
        XCTAssertEqual(adaptive.assistedDepthFrames, 0)
    }

    func testAdaptiveShadowDoesNotCountAcrossExplicitReset() throws {
        var session = adaptiveSession(
            standingFirst: true,
            bothLowered: true,
            legacyDepth: false
        )
        let resetIndex = 22
        let resetTimestamp = session.events[resetIndex].seconds
        session.events[resetIndex] = PoseReplayEvent(
            seconds: resetTimestamp,
            kind: .reset,
            pose: nil
        )
        let adaptive = try PoseReplayAdaptiveDepthAudit.replay(session)
        XCTAssertEqual(adaptive.countedAtSeconds.count, 0)
    }

    func testGraceRetainsLoweredPhaseAcrossSingleUnreliableFrame() throws {
        let session = graceSession(unreliableFrames: [25])
        let original = try PoseReplayRunner.replay(session)
        let adaptive = try PoseReplayAdaptiveDepthAudit.replay(session)
        let graceful = try PoseReplayAdaptiveDepthAudit.replayWithGrace(session)

        XCTAssertEqual(original.countedAtSeconds.count, 0)
        XCTAssertEqual(adaptive.countedAtSeconds.count, 0)
        XCTAssertEqual(graceful.countedAtSeconds.count, 1)
        XCTAssertEqual(graceful.heldLegFrames, 1)
        XCTAssertEqual(graceful.assistedDepthFrames, 0)
    }

    func testGraceExpiresAfterSustainedUnreliableFrames() throws {
        let session = graceSession(unreliableFrames: [24, 25, 26, 27, 28, 29])
        let graceful = try PoseReplayAdaptiveDepthAudit.replayWithGrace(session)
        XCTAssertEqual(graceful.countedAtSeconds.count, 0)
        XCTAssertGreaterThan(graceful.heldLegFrames, 0)
    }

    func testGraceDoesNotCountTwoFrameShallowAttempt() throws {
        let standingPose = adaptivePose(
            loweredLeft: false, loweredRight: false,
            legacyDepth: true, rightConfidence: 0.93
        )
        let loweredPose = adaptivePose(
            loweredLeft: true, loweredRight: false,
            legacyDepth: true, rightConfidence: 0.93
        )
        let unreliablePose = adaptivePose(
            loweredLeft: true, loweredRight: false,
            legacyDepth: true, rightConfidence: 0.93,
            leftConfidence: 0.49
        )
        var recorder = PoseReplayRecorder()
        _ = recorder.start(at: 0)
        var currentTime = 0.0
        for (pose, frameCount) in [
            (standingPose, 20), (loweredPose, 2),
            (unreliablePose, 1), (standingPose, 20)
        ] {
            for _ in 0..<frameCount {
                currentTime += 0.08
                recorder.append(pose, at: currentTime)
            }
        }
        let graceful = try PoseReplayAdaptiveDepthAudit.replayWithGrace(recorder.session)
        XCTAssertEqual(graceful.countedAtSeconds.count, 0)
        XCTAssertEqual(graceful.heldLegFrames, 1)
    }

    func testGraceCannotCountAcrossExplicitReset() throws {
        var session = graceSession(unreliableFrames: [25])
        let resetTimestamp = session.events[26].seconds
        session.events[26] = PoseReplayEvent(
            seconds: resetTimestamp,
            kind: .reset,
            pose: nil
        )
        let graceful = try PoseReplayAdaptiveDepthAudit.replayWithGrace(session)
        XCTAssertEqual(graceful.countedAtSeconds.count, 0)
    }

    private func graceSession(unreliableFrames: [Int]) -> PoseReplaySession {
        var session = adaptiveSession(
            standingFirst: true,
            bothLowered: false,
            legacyDepth: true
        )
        let unreliablePose = adaptivePose(
            loweredLeft: true,
            loweredRight: false,
            legacyDepth: true,
            rightConfidence: 0.93,
            leftConfidence: 0.49
        )
        for frameIndex in unreliableFrames {
            let timestamp = session.events[frameIndex].seconds
            session.events[frameIndex] = PoseReplayEvent(
                seconds: timestamp,
                kind: .pose,
                pose: PoseReplayPose(from: unreliablePose)
            )
        }
        return session
    }

    private func adaptiveSession(
        standingFirst: Bool,
        bothLowered: Bool,
        legacyDepth: Bool,
        rightConfidence: Float = 0.93
    ) -> PoseReplaySession {
        let standingPose = adaptivePose(
            loweredLeft: false,
            loweredRight: false,
            legacyDepth: legacyDepth,
            rightConfidence: rightConfidence
        )
        let loweredPose = adaptivePose(
            loweredLeft: true,
            loweredRight: bothLowered,
            legacyDepth: legacyDepth,
            rightConfidence: rightConfidence
        )
        var recorder = PoseReplayRecorder()
        _ = recorder.start(at: 0)
        var currentTime = 0.0
        let phases: [(BodyPose, Int)] = standingFirst
            ? [(standingPose, 20), (loweredPose, 20), (standingPose, 20)]
            : [(loweredPose, 20), (standingPose, 20)]
        for (pose, frameCount) in phases {
            for _ in 0..<frameCount {
                currentTime += 0.08
                recorder.append(pose, at: currentTime)
            }
        }
        return recorder.session
    }

    private func adaptivePose(
        loweredLeft: Bool,
        loweredRight: Bool,
        legacyDepth: Bool,
        rightConfidence: Float,
        leftConfidence: Float = 0.93
    ) -> BodyPose {
        var joints: [BodyJoint: JointPoint] = [:]
        for (bodyLeg, horizontalCenter, lowered) in [
            (BodyLeg.left, 0.35, loweredLeft),
            (BodyLeg.right, 0.65, loweredRight)
        ] {
            let hipJoint: BodyJoint = bodyLeg == .left ? .leftHip : .rightHip
            let kneeJoint: BodyJoint = bodyLeg == .left ? .leftKnee : .rightKnee
            let ankleJoint: BodyJoint = bodyLeg == .left ? .leftAnkle : .rightAnkle
            let confidence: Float = bodyLeg == .left ? leftConfidence : rightConfidence
            let hipPosition = lowered
                ? CGPoint(x: horizontalCenter + 0.13, y: legacyDepth ? 0.47 : 0.50)
                : CGPoint(x: horizontalCenter, y: 0.80)
            let kneePosition = lowered
                ? CGPoint(x: horizontalCenter, y: 0.445)
                : CGPoint(x: horizontalCenter, y: 0.50)
            let anklePosition = lowered
                ? CGPoint(x: horizontalCenter + 0.05, y: 0.25)
                : CGPoint(x: horizontalCenter, y: 0.20)
            joints[hipJoint] = JointPoint(location: hipPosition, confidence: confidence)
            joints[kneeJoint] = JointPoint(location: kneePosition, confidence: confidence)
            joints[ankleJoint] = JointPoint(location: anklePosition, confidence: confidence)
        }
        return BodyPose(joints: joints, aspectRatio: 1, rotationAngle: 90)
    }

    private func depthAuditPose(
        hipPosition: CGPoint,
        kneePosition: CGPoint,
        anklePosition: CGPoint,
        kneeConfidence: Float = 0.93
    ) -> BodyPose {
        let joints: [BodyJoint: JointPoint] = [
            .leftHip: JointPoint(location: hipPosition, confidence: 0.93),
            .leftKnee: JointPoint(location: kneePosition, confidence: kneeConfidence),
            .leftAnkle: JointPoint(location: anklePosition, confidence: 0.93)
        ]
        return BodyPose(joints: joints, aspectRatio: 1, rotationAngle: 90)
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

@MainActor
private final class PoseReplayClock: WorkoutTimeSource {
    var currentTime: TimeInterval = 0
    var date: Date { Date(timeIntervalSince1970: 0) }
}

@MainActor
private final class PoseReplayStore: WorkoutStoring {
    private var summaries: [WorkoutSummary] = []

    func save(_ summary: WorkoutSummary) throws {
        summaries.append(summary)
    }

    func history() throws -> [WorkoutSummary] {
        summaries
    }
}
