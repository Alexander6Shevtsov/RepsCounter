//
//  PoseAnalyzerTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreGraphics
import XCTest
#if DEBUG
import simd
#endif
@testable import RepsCounter

final class PoseAnalyzerTests: XCTestCase {
    func testInitialSelectionUsesLowestJointConfidenceForEachLeg() {
        var pose = SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170, leftConfidence: 0.9, rightConfidence: 0.8)
        pose = SquatPoseFixture.replacing(pose, joint: .leftAnkle, confidence: 0.6)
        let analysis = PoseAnalyzer().analyze(pose)
        XCTAssertEqual(analysis.selectedLeg, .right)
        XCTAssertEqual(analysis.leftMeasurement.confidence, 0.6)
    }

    func testEqualConfidenceHasDeterministicInitialSelection() {
        let analysis = PoseAnalyzer().analyze(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 165))
        XCTAssertEqual(analysis.selectedLeg, .left)
        XCTAssertEqual(analysis.measuredAngle ?? 0, 170, accuracy: 0.001)
    }

    func testSelectedRightLegStaysSelectedWhenLeftConfidenceImproves() {
        let analyzer = PoseAnalyzer()
        let first = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 165, leftConfidence: 0.6, rightConfidence: 0.8))
        let next = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 100, rightAngle: 165, leftConfidence: 1, rightConfidence: 0.7))
        XCTAssertEqual(first.selectedLeg, .right)
        XCTAssertEqual(next.selectedLeg, .right)
        XCTAssertFalse(next.requiresMovementReset)
        XCTAssertEqual(next.smoothedAngle ?? 0, 165, accuracy: 0.001)
    }

    func testConfidenceFluctuationsDoNotAlternateReliableLegs() {
        let analyzer = PoseAnalyzer()
        for index in 0..<20 {
            let analysis = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 90, leftConfidence: index.isMultiple(of: 2) ? 0.9 : 0.6, rightConfidence: 0.8))
            XCTAssertEqual(analysis.selectedLeg, .left)
            XCTAssertEqual(analysis.smoothedAngle ?? 0, 170, accuracy: 0.001)
            XCTAssertFalse(analysis.requiresMovementReset)
        }
    }

    func testFallbackToOtherLegResetsSmoothingAndInvalidatesMovement() {
        let analyzer = PoseAnalyzer()
        _ = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 90, rightAngle: 170, rightConfidence: 0.7))
        let analysis = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 90, rightAngle: 170, leftConfidence: 0.49, rightConfidence: 0.7))
        XCTAssertEqual(analysis.selectedLeg, .right)
        XCTAssertTrue(analysis.requiresMovementReset)
        XCTAssertEqual(analysis.smoothedAngle ?? 0, 170, accuracy: 0.001)
    }

    func testMissingHipKneeOrAnkleRejectsLegAndPreservesConfidenceEvidence() {
        for joint in [BodyJoint.leftHip, .leftKnee, .leftAnkle] {
            var joints = SquatPoseFixture.pose().joints
            joints.removeValue(forKey: joint)
            let analysis = PoseAnalyzer().analyze(BodyPose(joints: joints, aspectRatio: 1))
            XCTAssertNil(analysis.selectedLeg)
            XCTAssertNil(analysis.smoothedAngle)
            XCTAssertEqual(analysis.leftMeasurement.issue, .missingJoint)
            XCTAssertTrue(analysis.requiresMovementReset)
        }
    }

    func testLowConfidenceOnEachJointRejectsLegButShowsRawAngle() {
        for joint in [BodyJoint.leftHip, .leftKnee, .leftAnkle] {
            let pose = SquatPoseFixture.replacing(SquatPoseFixture.pose(leftAngle: 95), joint: joint, confidence: 0.49)
            let analysis = PoseAnalyzer().analyze(pose)
            XCTAssertEqual(analysis.leftMeasurement.issue, .lowConfidence)
            XCTAssertEqual(analysis.leftMeasurement.angle ?? 0, 95, accuracy: 0.001)
            XCTAssertNil(analysis.smoothedAngle)
        }
    }

    func testConfidenceBoundaryIsInclusiveAndNonfiniteConfidenceIsRejected() {
        XCTAssertEqual(PoseAnalyzer().analyze(SquatPoseFixture.pose(leftConfidence: 0.5)).selectedLeg, .left)
        for confidence in [Float.nan, .infinity, -1, 1.1] {
            let analysis = PoseAnalyzer().analyze(SquatPoseFixture.replacing(SquatPoseFixture.pose(), joint: .leftKnee, confidence: confidence))
            XCTAssertNil(analysis.selectedLeg)
            XCTAssertEqual(analysis.leftMeasurement.issue, .lowConfidence)
        }
    }

    func testSmoothingRetainsExistingExponentialCoefficient() {
        let analyzer = PoseAnalyzer()
        _ = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 170))
        let second = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 90))
        let third = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 90))
        XCTAssertEqual(second.measuredAngle ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(second.smoothedAngle ?? 0, 142, accuracy: 0.001)
        XCTAssertEqual(third.smoothedAngle ?? 0, 123.8, accuracy: 0.001)
    }

    func testSingleMissingObservationClearsFilterAndSelection() {
        let analyzer = PoseAnalyzer()
        _ = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 90))
        let missing = analyzer.analyze(nil)
        let restored = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 170))
        XCTAssertNil(missing.selectedLeg)
        XCTAssertTrue(missing.requiresMovementReset)
        XCTAssertEqual(restored.smoothedAngle ?? 0, 170, accuracy: 0.001)
    }

    func testExplicitResetClearsLegPreferenceAndSmoothing() {
        let analyzer = PoseAnalyzer()
        _ = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 90, rightAngle: 170))
        analyzer.reset()
        let restored = analyzer.analyze(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 160, leftConfidence: 0.6, rightConfidence: 0.9))
        XCTAssertEqual(restored.selectedLeg, .right)
        XCTAssertEqual(restored.smoothedAngle ?? 0, 160, accuracy: 0.001)
    }

    func testHipKneeHeightRatioHasPositiveZeroAndNegativeValues() {
        let samples: [(CGFloat, Double)] = [
            (0.6, sqrt(0.5)),
            (0.5, 0),
            (0.4, -sqrt(0.5))
        ]
        for sample in samples {
            let pose = SquatPoseFixture.replacing(
                SquatPoseFixture.pose(),
                joint: .leftHip,
                location: CGPoint(x: 0.6, y: sample.0)
            )
            let analysis = PoseAnalyzer().analyze(pose)
            XCTAssertEqual(analysis.selectedLeg, .left)
            XCTAssertEqual(analysis.hipKneeHeightRatio ?? -2, sample.1, accuracy: 0.001)
        }
    }

    func testHipKneeHeightRatioAccountsForImageAspectRatio() {
        let pose = SquatPoseFixture.replacing(
            SquatPoseFixture.pose(aspectRatio: 0.5),
            joint: .leftHip,
            location: CGPoint(x: 0.9, y: 0.7)
        )
        let analysis = PoseAnalyzer().analyze(pose)
        XCTAssertEqual(analysis.hipKneeHeightRatio ?? -2, sqrt(0.5), accuracy: 0.001)
    }

    func testHipKneeHeightRatioUsesSelectedReliableLeg() {
        var pose = SquatPoseFixture.pose(
            leftAngle: 170,
            rightAngle: 165,
            leftConfidence: 0.6,
            rightConfidence: 0.9
        )
        pose = SquatPoseFixture.replacing(pose, joint: .rightHip, location: CGPoint(x: 0.6, y: 0.4))
        let analysis = PoseAnalyzer().analyze(pose)
        XCTAssertEqual(analysis.selectedLeg, .right)
        XCTAssertEqual(analysis.hipKneeHeightRatio ?? 2, -sqrt(0.5), accuracy: 0.001)
    }

    func testHipKneeHeightRatioIsUnavailableForUnreliableGeometry() {
        let source = SquatPoseFixture.pose()
        let lowConfidence = SquatPoseFixture.replacing(source, joint: .leftKnee, confidence: 0.49)
        XCTAssertNil(PoseAnalyzer().analyze(lowConfidence).hipKneeHeightRatio)
        let coincident = SquatPoseFixture.replacing(
            source,
            joint: .leftHip,
            location: CGPoint(x: 0.5, y: 0.5)
        )
        XCTAssertNil(PoseAnalyzer().analyze(coincident).hipKneeHeightRatio)
        let invalidRatio = SquatPoseFixture.pose(aspectRatio: .nan)
        XCTAssertNil(PoseAnalyzer().analyze(invalidRatio).hipKneeHeightRatio)
        XCTAssertNil(PoseAnalyzer().analyze(nil).hipKneeHeightRatio)
    }

    func testAngleUsesImageAspectRatio() {
        let analysis = PoseAnalyzer().analyze(SquatPoseFixture.pose(leftAngle: 100, aspectRatio: 9.0 / 16.0))
        XCTAssertEqual(analysis.measuredAngle ?? 0, 100, accuracy: 0.001)
    }

    func testInvalidAspectRatioCannotProduceReliableMeasurement() {
        for ratio in [CGFloat.zero, -1, .nan, .infinity] {
            let analysis = PoseAnalyzer().analyze(SquatPoseFixture.pose(aspectRatio: ratio))
            XCTAssertNil(analysis.smoothedAngle)
            XCTAssertEqual(analysis.leftMeasurement.issue, .invalidGeometry)
        }
    }

    func testNonfiniteAndCoincidentJointLocationsAreRejected() {
        for location in [CGPoint(x: CGFloat.nan, y: 0.5), CGPoint(x: CGFloat.infinity, y: 0.5), CGPoint(x: 0.5, y: 0.5)] {
            let pose = SquatPoseFixture.replacing(SquatPoseFixture.pose(), joint: .leftHip, location: location)
            let analysis = PoseAnalyzer().analyze(pose)
            XCTAssertNil(analysis.smoothedAngle)
            XCTAssertEqual(analysis.leftMeasurement.issue, .invalidGeometry)
        }
    }

    func testReflectionPreservesKneeAngle() {
        let pose = SquatPoseFixture.pose(leftAngle: 100, aspectRatio: 9.0 / 16.0)
        let reflected = BodyPose(joints: pose.joints.mapValues { JointPoint(location: CGPoint(x: 1 - $0.location.x, y: $0.location.y), confidence: $0.confidence) }, aspectRatio: pose.aspectRatio)
        XCTAssertEqual(PoseAnalyzer().analyze(pose).measuredAngle ?? 0, PoseAnalyzer().analyze(reflected).measuredAngle ?? 1, accuracy: 0.001)
    }

    func testFrontProjectionCanLookStraightDuringTrueDeepSquat() {
        let front = SquatPoseFixture.projectedPose(kneeAngle: 100, cameraYaw: 0)
        let side = SquatPoseFixture.projectedPose(kneeAngle: 100, cameraYaw: 90)
        XCTAssertEqual(PoseAnalyzer().analyze(front).measuredAngle ?? 0, 180, accuracy: 0.001)
        XCTAssertEqual(PoseAnalyzer().analyze(side).measuredAngle ?? 0, 100, accuracy: 0.001)
    }

    func testFortyFiveDegreeProjectionCanMissExistingDepthThreshold() {
        let angled = PoseAnalyzer().analyze(SquatPoseFixture.projectedPose(kneeAngle: 104, cameraYaw: 45))
        let side = PoseAnalyzer().analyze(SquatPoseFixture.projectedPose(kneeAngle: 104, cameraYaw: 90))
        XCTAssertGreaterThan(angled.measuredAngle ?? 0, 105)
        XCTAssertLessThanOrEqual(side.measuredAngle ?? 180, 105)
    }

    #if DEBUG
    func testThreeDimensionalAngleIsStableUnderHorizontalCameraRotation() throws {
        let kneePosition = SIMD3<Float>(0, 0, 0)
        let anklePosition = SIMD3<Float>(0, -1, 0)
        let yawSamples: [Float] = [0, Float.pi / 4, Float.pi / 2]
        for yawRadians in yawSamples {
            let hipPosition = SIMD3<Float>(cos(yawRadians), 0, sin(yawRadians))
            let metrics = try XCTUnwrap(Vision3DGeometry.metrics(
                hipPosition: hipPosition,
                kneePosition: kneePosition,
                anklePosition: anklePosition
            ))
            XCTAssertEqual(metrics.angle, 90, accuracy: 0.01)
            XCTAssertEqual(metrics.heightRatio, 0, accuracy: 0.01)
        }
    }

    func testThreeDimensionalVerticalGeometryAndInvalidJoints() throws {
        let kneePosition = SIMD3<Float>(0, 0, 0)
        let hipPosition = SIMD3<Float>(0, 1, 0)
        let anklePosition = SIMD3<Float>(0, -1, 0)
        let metrics = try XCTUnwrap(Vision3DGeometry.metrics(
            hipPosition: hipPosition,
            kneePosition: kneePosition,
            anklePosition: anklePosition
        ))
        XCTAssertEqual(metrics.angle, 180, accuracy: 0.01)
        XCTAssertEqual(metrics.heightRatio, 1, accuracy: 0.01)
        XCTAssertNil(Vision3DGeometry.metrics(
            hipPosition: kneePosition,
            kneePosition: kneePosition,
            anklePosition: anklePosition
        ))
        XCTAssertNil(Vision3DGeometry.metrics(
            hipPosition: SIMD3<Float>(Float.nan, 0, 0),
            kneePosition: kneePosition,
            anklePosition: anklePosition
        ))
    }
    func testThreeDimensionalSamplerTargetsFiveToTenSamplesPerSecond() {
        var sampler = Vision3DSamplingController()
        let timestamp = ContinuousClock.now
        for offset in 0..<25 {
            sampler.recordTwoDimensionalFrame(at: timestamp.advanced(by: .milliseconds(offset * 80)))
        }
        XCTAssertEqual(sampler.twoDimensionalFramesPerSecond ?? 0, 12.5, accuracy: 0.01)

        XCTAssertTrue(sampler.shouldSampleThreeDimensional(at: timestamp, enabled: true))
        sampler.recordThreeDimensionalSample(at: timestamp, latencyMilliseconds: 40)

        XCTAssertFalse(sampler.shouldSampleThreeDimensional(
            at: timestamp.advanced(by: .milliseconds(80)),
            enabled: true
        ))
        let secondSample = timestamp.advanced(by: .milliseconds(160))
        XCTAssertTrue(sampler.shouldSampleThreeDimensional(at: secondSample, enabled: true))
        sampler.recordThreeDimensionalSample(at: secondSample, latencyMilliseconds: 40)

        XCTAssertFalse(sampler.shouldSampleThreeDimensional(
            at: timestamp.advanced(by: .milliseconds(240)),
            enabled: true
        ))
        let thirdSample = timestamp.advanced(by: .milliseconds(320))
        XCTAssertTrue(sampler.shouldSampleThreeDimensional(at: thirdSample, enabled: true))
        sampler.recordThreeDimensionalSample(at: thirdSample, latencyMilliseconds: 40)

        XCTAssertEqual(sampler.sampleCount, 3)
        XCTAssertEqual(sampler.threeDimensionalSamplesPerSecond ?? 0, 6.25, accuracy: 0.01)
    }

    func testSlowVisionThreeDimensionalRequestIncreasesSamplingCooldown() {
        var sampler = Vision3DSamplingController()
        let timestamp = ContinuousClock.now
        XCTAssertTrue(sampler.shouldSampleThreeDimensional(at: timestamp, enabled: true))
        sampler.recordThreeDimensionalSample(at: timestamp, latencyMilliseconds: 130)

        XCTAssertFalse(sampler.shouldSampleThreeDimensional(
            at: timestamp.advanced(by: .milliseconds(200)),
            enabled: true
        ))
        XCTAssertFalse(sampler.shouldSampleThreeDimensional(
            at: timestamp.advanced(by: .milliseconds(259)),
            enabled: true
        ))
        XCTAssertTrue(sampler.shouldSampleThreeDimensional(
            at: timestamp.advanced(by: .milliseconds(260)),
            enabled: true
        ))
        sampler.recordThreeDimensionalSample(
            at: timestamp.advanced(by: .milliseconds(260)),
            latencyMilliseconds: 130
        )
        XCTAssertEqual(sampler.threeDimensionalSamplesPerSecond ?? 0, 1 / 0.26, accuracy: 0.01)

        XCTAssertFalse(sampler.shouldSampleThreeDimensional(
            at: timestamp.advanced(by: .milliseconds(270)),
            enabled: false
        ))
        XCTAssertEqual(sampler.sampleCount, 0)
        XCTAssertNil(sampler.threeDimensionalSamplesPerSecond)
        XCTAssertTrue(sampler.shouldSampleThreeDimensional(
            at: timestamp.advanced(by: .milliseconds(271)),
            enabled: true
        ))
    }

    func testExperimentalThreeDimensionalCounterCountsTwoCompleteCyclesOnly() {
        var counter = Vision3DExperimentalCounter()
        let upright = SquatPoseFixture.experimental3DProbe(leftAngle: 160, leftHeight: 0.96)
        let deep = SquatPoseFixture.experimental3DProbe(leftAngle: 75, leftHeight: 0.18)
        XCTAssertFalse(counter.process(upright, at: 0))
        XCTAssertFalse(counter.process(upright, at: 0.20))
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertEqual(counter.standingHipKneeRatio ?? 0, 0.96, accuracy: 0.001)
        XCTAssertFalse(counter.process(deep, at: 0.40))
        XCTAssertFalse(counter.process(deep, at: 0.60))
        XCTAssertEqual(counter.phase, .lowered)
        XCTAssertFalse(counter.process(upright, at: 0.80))
        XCTAssertTrue(counter.process(upright, at: 1.00))
        XCTAssertEqual(counter.repetitions, 1)
        XCTAssertFalse(counter.process(upright, at: 1.20))
        XCTAssertFalse(counter.process(upright, at: 1.40))
        XCTAssertEqual(counter.repetitions, 1)
        XCTAssertFalse(counter.process(deep, at: 1.60))
        XCTAssertFalse(counter.process(deep, at: 1.80))
        XCTAssertFalse(counter.process(upright, at: 2.00))
        XCTAssertTrue(counter.process(upright, at: 2.20))
        XCTAssertEqual(counter.repetitions, 2)
        XCTAssertEqual(counter.interruptions, 0)
    }

    func testExperimentalThreeDimensionalRejectsPartialDespiteSmallKneeAngle() {
        var counter = Vision3DExperimentalCounter()
        let upright = SquatPoseFixture.experimental3DProbe(leftAngle: 155, leftHeight: 0.96)
        let partial = SquatPoseFixture.experimental3DProbe(leftAngle: 99.5, leftHeight: 0.59)
        XCTAssertFalse(counter.process(upright, at: 0))
        XCTAssertFalse(counter.process(upright, at: 0.20))
        for timestamp in [0.40, 0.60, 0.80] {
            XCTAssertFalse(counter.process(partial, at: timestamp))
            XCTAssertEqual(counter.decision, .insufficientDescent)
        }
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertEqual(counter.relativeDescent ?? 0, 0.37, accuracy: 0.001)
        XCTAssertFalse(counter.process(upright, at: 1.00))
        XCTAssertFalse(counter.process(upright, at: 1.20))
        XCTAssertEqual(counter.repetitions, 0)
    }

    func testExperimentalThreeDimensionalLossCannotCompleteOldSquat() {
        var counter = Vision3DExperimentalCounter()
        let upright = SquatPoseFixture.experimental3DProbe(leftAngle: 155, leftHeight: 0.96)
        let deep = SquatPoseFixture.experimental3DProbe(leftAngle: 70, leftHeight: 0.18)
        let unavailable = SquatPoseFixture.experimental3DProbe(
            leftAngle: nil, leftHeight: nil, available: false
        )
        _ = counter.process(upright, at: 0)
        _ = counter.process(upright, at: 0.20)
        _ = counter.process(deep, at: 0.40)
        _ = counter.process(deep, at: 0.60)
        XCTAssertEqual(counter.phase, .lowered)
        XCTAssertFalse(counter.process(unavailable, at: 0.80))
        XCTAssertEqual(counter.decision, .invalidMeasurement)
        XCTAssertEqual(counter.phase, .seekingStanding)
        XCTAssertEqual(counter.interruptions, 1)
        XCTAssertFalse(counter.process(upright, at: 1.00))
        XCTAssertFalse(counter.process(upright, at: 1.20))
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertEqual(counter.repetitions, 0)
        _ = counter.process(deep, at: 1.40)
        _ = counter.process(deep, at: 1.60)
        XCTAssertFalse(counter.process(upright, at: 1.80))
        XCTAssertTrue(counter.process(upright, at: 2.00))
        XCTAssertEqual(counter.repetitions, 1)
    }

    func testExperimentalThreeDimensionalGapAndLegChangeResetMovement() {
        var counter = Vision3DExperimentalCounter()
        let uprightLeft = SquatPoseFixture.experimental3DProbe(leftAngle: 155, leftHeight: 0.96)
        let deepLeft = SquatPoseFixture.experimental3DProbe(leftAngle: 70, leftHeight: 0.15)
        let uprightRight = SquatPoseFixture.experimental3DProbe(
            leftAngle: nil, leftHeight: nil, rightAngle: 150, rightHeight: 0.96
        )
        _ = counter.process(uprightLeft, at: 0)
        _ = counter.process(uprightLeft, at: 0.20)
        _ = counter.process(deepLeft, at: 0.40)
        _ = counter.process(deepLeft, at: 0.60)
        XCTAssertFalse(counter.process(uprightRight, at: 0.80))
        XCTAssertEqual(counter.phase, .seekingStanding)
        XCTAssertEqual(counter.interruptions, 1)
        XCTAssertFalse(counter.process(uprightRight, at: 1.00))
        XCTAssertFalse(counter.process(uprightRight, at: 1.20))
        XCTAssertEqual(counter.selectedLeg, .right)
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertEqual(counter.repetitions, 0)
        counter.expire(at: 2.01)
        XCTAssertEqual(counter.phase, .seekingStanding)
        XCTAssertEqual(counter.decision, .observationGap)
        XCTAssertEqual(counter.interruptions, 2)
        XCTAssertFalse(counter.process(uprightRight, at: 2.20))
        XCTAssertFalse(counter.process(uprightRight, at: 2.40))
        XCTAssertEqual(counter.repetitions, 0)
    }

    func testExperimentalThreeDimensionalRequiresDistinctTimedSamples() {
        var counter = Vision3DExperimentalCounter()
        let upright = SquatPoseFixture.experimental3DProbe(leftAngle: 155, leftHeight: 0.96)
        XCTAssertFalse(counter.process(upright, at: 0))
        XCTAssertFalse(counter.process(upright, at: 0))
        XCTAssertFalse(counter.process(upright, at: 0.05))
        XCTAssertEqual(counter.phase, .seekingStanding)
        XCTAssertFalse(counter.process(upright, at: 0.20))
        XCTAssertEqual(counter.phase, .standing)
        let skipped = SquatPoseFixture.experimental3DProbe(
            leftAngle: nil, leftHeight: nil, sampled: false
        )
        XCTAssertFalse(counter.process(skipped, at: 0.30))
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertFalse(counter.process(
            SquatPoseFixture.experimental3DProbe(leftAngle: .nan, leftHeight: 0.2),
            at: 0.40
        ))
        XCTAssertEqual(counter.phase, .seekingStanding)
        XCTAssertEqual(counter.decision, .invalidMeasurement)
    }

    #endif
}

enum SquatPoseFixture {
    static func pose(leftAngle: Double = 170, rightAngle: Double? = nil, leftConfidence: Float = 1, rightConfidence: Float = 1, aspectRatio: CGFloat = 1) -> BodyPose {
        var joints = legJoints(angle: leftAngle, confidence: leftConfidence, joints: [.leftHip, .leftKnee, .leftAnkle], aspectRatio: aspectRatio)
        if let rightAngle {
            joints.merge(legJoints(angle: rightAngle, confidence: rightConfidence, joints: [.rightHip, .rightKnee, .rightAnkle], aspectRatio: aspectRatio)) { first, _ in first }
        }
        return BodyPose(joints: joints, aspectRatio: aspectRatio)
    }

    #if DEBUG
    static func experimental3DProbe(
        leftAngle: Double?,
        leftHeight: Double?,
        rightAngle: Double? = nil,
        rightHeight: Double? = nil,
        available: Bool = true,
        sampled: Bool = true
    ) -> Vision3DProbe {
        Vision3DProbe(
            twoDimensionalLatencyMs: 13,
            threeDimensionalLatencyMs: sampled ? 40 : nil,
            leftKneeAngle: leftAngle,
            rightKneeAngle: rightAngle,
            leftHipKneeHeightRatio: leftHeight,
            rightHipKneeHeightRatio: rightHeight,
            sampleCount: 1,
            observationAvailable: available,
            twoDimensionalFramesPerSecond: 10,
            threeDimensionalSamplesPerSecond: 5
        )
    }
    #endif

    static func replacing(_ pose: BodyPose, joint: BodyJoint, confidence: Float? = nil, location: CGPoint? = nil) -> BodyPose {
        var joints = pose.joints
        if let original = joints[joint] {
            joints[joint] = JointPoint(location: location ?? original.location, confidence: confidence ?? original.confidence)
        }
        return BodyPose(joints: joints, aspectRatio: pose.aspectRatio)
    }

    static func projectedPose(kneeAngle: Double, cameraYaw: Double) -> BodyPose {
        let radians = kneeAngle * .pi / 180
        let yawRadians = cameraYaw * .pi / 180
        let hipPoint = CGPoint(x: 0.5 + 0.2 * sin(radians) * sin(yawRadians), y: 0.5 - 0.2 * cos(radians))
        return BodyPose(joints: [
            .leftHip: JointPoint(location: hipPoint, confidence: 1),
            .leftKnee: JointPoint(location: CGPoint(x: 0.5, y: 0.5), confidence: 1),
            .leftAnkle: JointPoint(location: CGPoint(x: 0.5, y: 0.3), confidence: 1)
        ], aspectRatio: 1)
    }

    private static func legJoints(angle: Double, confidence: Float, joints: [BodyJoint], aspectRatio: CGFloat) -> [BodyJoint: JointPoint] {
        let radians = angle * .pi / 180
        let scale = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1
        return [
            joints[0]: JointPoint(location: CGPoint(x: 0.5 + 0.2 * sin(radians) / scale, y: 0.5 - 0.2 * cos(radians)), confidence: confidence),
            joints[1]: JointPoint(location: CGPoint(x: 0.5, y: 0.5), confidence: confidence),
            joints[2]: JointPoint(location: CGPoint(x: 0.5, y: 0.3), confidence: confidence)
        ]
    }
}
