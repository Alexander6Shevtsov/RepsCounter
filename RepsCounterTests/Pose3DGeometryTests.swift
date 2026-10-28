//
//  Pose3DGeometryTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

#if DEBUG
import CoreGraphics
import simd
import XCTest
@testable import RepsCounter

final class Pose3DGeometryTests: XCTestCase {
    func testStraightSpatialKneeIs180Degrees() throws {
        let measured = try XCTUnwrap(SpatialJointGeometry.angle(first: [0, 1, 0], vertex: .zero, third: [0, -1, 0]))
        XCTAssertEqual(measured, 180, accuracy: 0.000001)
    }

    func testRightSpatialKneeIs90Degrees() throws {
        let measured = try XCTUnwrap(SpatialJointGeometry.angle(first: [0, 1, 0], vertex: .zero, third: [0, 0, 1]))
        XCTAssertEqual(measured, 90, accuracy: 0.000001)
    }

    func testSpatialAngleIsStableUnderRotationTranslationAndMirror() throws {
        let points: [SIMD3<Double>] = [[0, 1, 0], .zero, [0, -0.5, 0.866025403784]]
        let reference = try XCTUnwrap(SpatialJointGeometry.angle(first: points[0], vertex: points[1], third: points[2]))
        for yawAngle in [0.0, 45, 90, 180] {
            for mirror in [-1.0, 1] {
                let transformed = points.map { point -> SIMD3<Double> in
                    let rotated = Pose3DFixture.rotate(point, yawAngle: yawAngle)
                    return SIMD3(rotated.x * mirror + 4, rotated.y - 2, rotated.z + 7)
                }
                let measured = try XCTUnwrap(SpatialJointGeometry.angle(first: transformed[0], vertex: transformed[1], third: transformed[2]))
                XCTAssertEqual(measured, reference, accuracy: 0.000001)
            }
        }
    }

    func testFrontDiagonalAndSideProjectionChange2DButPreserve3DAngle() throws {
        var planarAngles: [Double] = []
        for yawAngle in [0.0, 45, 90] {
            let points = [SIMD3<Double>(0, 1, 0), .zero, SIMD3<Double>(0, -0.5, 0.866025403784)]
                .map { Pose3DFixture.rotate($0, yawAngle: yawAngle) }
            let planar = try XCTUnwrap(JointAngleCalculator.angle(
                first: CGPoint(x: points[0].x, y: points[0].y), vertex: .zero,
                third: CGPoint(x: points[2].x, y: points[2].y)
            ))
            planarAngles.append(planar)
            let spatial = try XCTUnwrap(SpatialJointGeometry.angle(first: points[0], vertex: points[1], third: points[2]))
            XCTAssertEqual(spatial, 120, accuracy: 0.000001)
        }
        XCTAssertEqual(planarAngles[0], 180, accuracy: 0.000001)
        XCTAssertEqual(planarAngles[2], 120, accuracy: 0.000001)
        XCTAssertGreaterThan(planarAngles[1], planarAngles[2])
    }

    func testIdentical2DPointsCanRepresentDifferentSpatialKnees() throws {
        let hipPoint = SIMD3<Double>(0, 1, 0)
        let firstAnkle = SIMD3<Double>(1, -1, 0)
        let secondAnkle = SIMD3<Double>(1, -1, 3)
        let firstAngle = try XCTUnwrap(SpatialJointGeometry.angle(first: hipPoint, vertex: .zero, third: firstAnkle))
        let secondAngle = try XCTUnwrap(SpatialJointGeometry.angle(first: hipPoint, vertex: .zero, third: secondAnkle))
        XCTAssertGreaterThan(abs(firstAngle - secondAngle), 15)
        XCTAssertEqual(CGPoint(x: firstAnkle.x, y: firstAnkle.y), CGPoint(x: secondAnkle.x, y: secondAnkle.y))
    }

    func testAngleRejectsNaNInfinityAndOverflow() {
        for coordinate in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            XCTAssertNil(SpatialJointGeometry.angle(first: [coordinate, 1, 0], vertex: .zero, third: [0, -1, 0]))
        }
    }

    func testAngleRejectsCoincidentAndNumericallyDegenerateJoints() {
        XCTAssertNil(SpatialJointGeometry.angle(first: .zero, vertex: .zero, third: [0, -1, 0]))
        XCTAssertNil(SpatialJointGeometry.angle(first: [0, 1, 0], vertex: .zero, third: [0, 0.0000000001, 0]))
    }

    func testBothLegsUseRootPositionsAndKeepAnatomicalIdentity() throws {
        let analysis = ExperimentalDepthAnalysis(pose: Pose3DFixture.pose(leftAngle: 90, rightAngle: 150))
        XCTAssertEqual(try XCTUnwrap(analysis.leftLeg.angle), 90, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(analysis.rightLeg.angle), 150, accuracy: 0.000001)
        XCTAssertTrue(analysis.leftLeg.isUsable)
        XCTAssertTrue(analysis.rightLeg.isUsable)
    }

    func testMissingAnkleRejectsOnlyAffectedLeg() {
        var joints = Pose3DFixture.pose().joints
        joints.removeValue(forKey: .leftAnkle)
        let analysis = ExperimentalDepthAnalysis(pose: BodyPose3D(joints: joints))
        XCTAssertEqual(analysis.leftLeg.issue, .missingJoint)
        XCTAssertTrue(analysis.rightLeg.isUsable)
        XCTAssertEqual(analysis.decision, .indeterminateDepth)
    }

    func testInvalidJointRejectsGeometryWithoutInventingConfidence() {
        var joints = Pose3DFixture.pose().joints
        joints[.leftHip] = [Double.nan, 0, 0]
        let analysis = ExperimentalDepthAnalysis(pose: BodyPose3D(joints: joints))
        XCTAssertEqual(analysis.leftLeg.issue, .invalidGeometry)
        XCTAssertNil(analysis.leftLeg.angle)
        XCTAssertNil(analysis.leftLeg.hipMinusKneeModelY)
    }

    func testMissingBodyHasUnavailablePhase() {
        let analysis = ExperimentalDepthAnalysis(pose: nil)
        XCTAssertEqual(analysis.phase, .unavailable)
        XCTAssertEqual(analysis.decision, .rejectedMeasurement)
        XCTAssertNil(analysis.confirmedRepetitions)
    }

    func testModelVerticalOffsetIsDescriptiveAndDoesNotClassifyPhysicalDepth() throws {
        let analysis = ExperimentalDepthAnalysis(pose: Pose3DFixture.pose(leftAngle: 90))
        XCTAssertEqual(try XCTUnwrap(analysis.leftLeg.hipMinusKneeModelY), 0.4, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(analysis.leftLeg.normalizedHipOffset), 1, accuracy: 0.000001)
        XCTAssertEqual(analysis.decision, .indeterminateDepth)
        XCTAssertNil(analysis.confirmedRepetitions)
    }

    func test2DThresholdsCannotProduceConfirmed3DRepetitionsOrDoubleCount() {
        for angle in [170.0, 100, 80, 170, 170, 100, 170] {
            let analysis = ExperimentalDepthAnalysis(pose: Pose3DFixture.pose(leftAngle: angle))
            XCTAssertNil(analysis.confirmedRepetitions)
            XCTAssertEqual(analysis.decision, .indeterminateDepth)
        }
    }

    func testTrackingLossNeverBridgesUnobserved3DMovement() {
        let observations: [BodyPose3D?] = [Pose3DFixture.pose(leftAngle: 170), Pose3DFixture.pose(leftAngle: 90), nil, Pose3DFixture.pose(leftAngle: 170)]
        for observation in observations {
            XCTAssertNil(ExperimentalDepthAnalysis(pose: observation).confirmedRepetitions)
        }
    }
}

enum Pose3DFixture {
    static func pose(leftAngle: Double = 120, rightAngle: Double = 120) -> BodyPose3D {
        var joints: [BodyJoint: SIMD3<Double>] = [:]
        for (offset, angle, names) in [
            (-0.15, leftAngle, [BodyJoint.leftHip, .leftKnee, .leftAnkle]),
            (0.15, rightAngle, [BodyJoint.rightHip, .rightKnee, .rightAnkle])
        ] {
            let radians = angle * .pi / 180
            joints[names[0]] = [offset, 0.4, 0]
            joints[names[1]] = [offset, 0, 0]
            joints[names[2]] = [offset, cos(radians) * 0.4, sin(radians) * 0.4]
        }
        return BodyPose3D(joints: joints)
    }

    static func rotate(_ point: SIMD3<Double>, yawAngle: Double) -> SIMD3<Double> {
        let radians = yawAngle * .pi / 180
        return [cos(radians) * point.x + sin(radians) * point.z, point.y, -sin(radians) * point.x + cos(radians) * point.z]
    }
}
#endif
