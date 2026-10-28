//
//  SquatDepthValidationTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreGraphics
import simd
import XCTest
@testable import RepsCounter

final class SquatDepthValidationTests: XCTestCase {
    func testObservedDepthConfirmationMatchesCounterRules() {
        var counter = standingCounter()
        _ = counter.process(measuredAngle: 105.4, smoothedAngle: 110.7)
        XCTAssertEqual(counter.consecutiveFrames, 0)
        _ = counter.process(measuredAngle: 103.6, smoothedAngle: 108.2)
        XCTAssertEqual(counter.consecutiveFrames, 1)
        XCTAssertEqual(counter.phase, .standing)
        _ = counter.process(measuredAngle: 102, smoothedAngle: 106)
        XCTAssertEqual(counter.consecutiveFrames, 2)
        XCTAssertEqual(counter.phase, .standing)
        _ = counter.process(measuredAngle: 100, smoothedAngle: 103.9)
        XCTAssertEqual(counter.phase, .lowered)
        XCTAssertEqual(counter.decision, .loweredConfirmed)
        XCTAssertEqual(counter.repetitions, 0)
    }

    func testObservedReturnWaitsForEMAAndCountsExactlyOnce() {
        var counter = counterAfterObservedDepth()
        for sample in [(160.6, 150.0), (164.6, 155.1), (168.2, 159.7)] {
            XCTAssertFalse(counter.process(measuredAngle: sample.0, smoothedAngle: sample.1))
        }
        XCTAssertEqual(counter.decision, .awaitingReturnSmoothing)
        XCTAssertEqual(counter.consecutiveFrames, 3)
        XCTAssertTrue(counter.process(measuredAngle: 172.9, smoothedAngle: 164.3))
        XCTAssertEqual(counter.repetitions, 1)
        for _ in 0..<20 {
            XCTAssertFalse(counter.process(measuredAngle: 172.9, smoothedAngle: 164.3))
        }
        XCTAssertEqual(counter.repetitions, 1)
    }

    func testKnownManuallyPartialCycleMustNotProduceCompleteRepetition() {
        var counter = counterAfterObservedDepth()
        for sample in [(160.6, 150.0), (164.6, 155.1), (168.2, 159.7), (172.9, 164.3)] {
            _ = counter.process(measuredAngle: sample.0, smoothedAngle: sample.1)
        }
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        XCTExpectFailure("FP-001: user labels the observed movement partial, but the current 2D depth proxy accepts it. See Docs/SQUAT_DEPTH_VALIDATION.md.", options: options) {
            XCTAssertEqual(counter.repetitions, 0, "A manually partial cycle must produce no complete repetitions")
        }
    }

    func testDifferentSpatialAnglesCanHaveIdentical2DObservations() throws {
        let planarHip = SIMD3<Double>(0.5, 0.5, 0)
        let planarAnkle = SIMD3<Double>(0.5, -0.5, 0)
        let spatialHip = SIMD3<Double>(0.5, 0.5, sqrt(0.5))
        let spatialAnkle = SIMD3<Double>(0.5, -0.5, -sqrt(0.5))
        let planarProjection = try XCTUnwrap(projectedAngle(hipPoint: planarHip, anklePoint: planarAnkle))
        let spatialProjection = try XCTUnwrap(projectedAngle(hipPoint: spatialHip, anklePoint: spatialAnkle))
        XCTAssertEqual(spatialAngle(hipVector: planarHip, ankleVector: planarAnkle), 90, accuracy: 0.001)
        XCTAssertEqual(spatialAngle(hipVector: spatialHip, ankleVector: spatialAnkle), 120, accuracy: 0.001)
        XCTAssertEqual(planarProjection, spatialProjection, accuracy: 0.001)
        XCTAssertEqual(spatialProjection, 90, accuracy: 0.001)
        XCTAssertLessThanOrEqual(spatialProjection, SquatCounter().loweredThreshold)
        XCTAssertGreaterThan(spatialAngle(hipVector: spatialHip, ankleVector: spatialAnkle), SquatCounter().loweredThreshold)
    }

    func testPerspectiveProjectionAlsoCannotDetermineSpatialKneeAngle() throws {
        let kneePoint = SIMD3<Double>(0, 0, 4)
        let planarHip = SIMD3<Double>(0.4, 0.4, 4)
        let planarAnkle = SIMD3<Double>(0.4, -0.4, 4)
        let spatialHip = SIMD3<Double>(0.46, 0.46, 4.6)
        let spatialAnkle = SIMD3<Double>(0.34, -0.34, 3.4)
        let planarProjection = try XCTUnwrap(JointAngleCalculator.angle(
            first: perspectivePoint(planarHip), vertex: perspectivePoint(kneePoint), third: perspectivePoint(planarAnkle)
        ))
        let spatialProjection = try XCTUnwrap(JointAngleCalculator.angle(
            first: perspectivePoint(spatialHip), vertex: perspectivePoint(kneePoint), third: perspectivePoint(spatialAnkle)
        ))
        XCTAssertEqual(planarProjection, spatialProjection, accuracy: 0.001)
        XCTAssertEqual(spatialProjection, 90, accuracy: 0.001)
        XCTAssertEqual(spatialAngle(hipVector: planarHip - kneePoint, ankleVector: planarAnkle - kneePoint), 90, accuracy: 0.001)
        XCTAssertGreaterThan(spatialAngle(hipVector: spatialHip - kneePoint, ankleVector: spatialAnkle - kneePoint), 105)
    }

    func testIdealSagittalYawAloneDoesNotExplainSmallerProjectedPartialAngle() throws {
        for yawDegrees in [0.0, 30, 45, 60, 90] {
            let pose = SquatPoseFixture.projectedPose(kneeAngle: 120, cameraYaw: yawDegrees)
            let measured = try XCTUnwrap(PoseAnalyzer().analyze(pose).measuredAngle)
            XCTAssertGreaterThanOrEqual(measured, 120 - 0.001)
            XCTAssertGreaterThan(measured, SquatCounter().loweredThreshold)
        }
    }

    func testSmallPointDisplacementCanCrossThresholdForForeshortenedLimb() throws {
        let kneePoint = CGPoint(x: 0.5, y: 0.5)
        let anklePoint = CGPoint(x: 0.5, y: 0.3)
        let straight = try XCTUnwrap(JointAngleCalculator.angle(first: CGPoint(x: 0.5, y: 0.502), vertex: kneePoint, third: anklePoint))
        let displaced = try XCTUnwrap(JointAngleCalculator.angle(first: CGPoint(x: 0.51, y: 0.502), vertex: kneePoint, third: anklePoint))
        XCTAssertEqual(straight, 180, accuracy: 0.001)
        XCTAssertLessThan(displaced, SquatCounter().loweredThreshold)
    }

    func testLowConfidenceUnselectedLegDoesNotInvalidateObservedRightLeg() {
        var pose = SquatPoseFixture.pose(leftAngle: 96.1, rightAngle: 98.5)
        pose = SquatPoseFixture.replacing(pose, joint: .leftHip, confidence: 0.49)
        pose = SquatPoseFixture.replacing(pose, joint: .leftKnee, confidence: 0.79)
        pose = SquatPoseFixture.replacing(pose, joint: .leftAnkle, confidence: 0.23)
        pose = SquatPoseFixture.replacing(pose, joint: .rightHip, confidence: 0.61)
        pose = SquatPoseFixture.replacing(pose, joint: .rightKnee, confidence: 0.80)
        pose = SquatPoseFixture.replacing(pose, joint: .rightAnkle, confidence: 0.73)
        let analysis = PoseAnalyzer().analyze(pose)
        XCTAssertEqual(analysis.selectedLeg, .right)
        XCTAssertEqual(analysis.leftMeasurement.issue, .lowConfidence)
        XCTAssertTrue(analysis.rightMeasurement.isReliable)
        XCTAssertEqual(analysis.measuredAngle ?? 0, 98.5, accuracy: 0.001)
    }

    private func standingCounter() -> SquatCounter {
        var counter = SquatCounter()
        for _ in 0..<3 { _ = counter.process(angle: 170) }
        return counter
    }

    private func counterAfterObservedDepth() -> SquatCounter {
        var counter = standingCounter()
        for sample in [(105.4, 110.7), (103.6, 108.2), (102.0, 106.0), (100.0, 103.9), (98.5, 100.9), (99.0, 98.7), (120.0, 112.2), (156.1, 144.3)] {
            _ = counter.process(measuredAngle: sample.0, smoothedAngle: sample.1)
        }
        return counter
    }

    private func spatialAngle(hipVector: SIMD3<Double>, ankleVector: SIMD3<Double>) -> Double {
        let cosine = simd_dot(hipVector, ankleVector) / (simd_length(hipVector) * simd_length(ankleVector))
        return acos(min(1, max(-1, cosine))) * 180 / .pi
    }

    private func perspectivePoint(_ point: SIMD3<Double>) -> CGPoint {
        CGPoint(x: point.x / point.z, y: point.y / point.z)
    }

    private func projectedAngle(hipPoint: SIMD3<Double>, anklePoint: SIMD3<Double>) -> Double? {
        JointAngleCalculator.angle(
            first: CGPoint(x: hipPoint.x, y: hipPoint.y),
            vertex: .zero,
            third: CGPoint(x: anklePoint.x, y: anklePoint.y)
        )
    }
}
