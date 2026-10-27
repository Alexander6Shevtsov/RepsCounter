//
//  PoseAnalyzerTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreGraphics
import XCTest
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
}

enum SquatPoseFixture {
    static func pose(leftAngle: Double = 170, rightAngle: Double? = nil, leftConfidence: Float = 1, rightConfidence: Float = 1, aspectRatio: CGFloat = 1) -> BodyPose {
        var joints = legJoints(angle: leftAngle, confidence: leftConfidence, joints: [.leftHip, .leftKnee, .leftAnkle], aspectRatio: aspectRatio)
        if let rightAngle {
            joints.merge(legJoints(angle: rightAngle, confidence: rightConfidence, joints: [.rightHip, .rightKnee, .rightAnkle], aspectRatio: aspectRatio)) { first, _ in first }
        }
        return BodyPose(joints: joints, aspectRatio: aspectRatio)
    }

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
