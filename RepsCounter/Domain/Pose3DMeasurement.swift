//
//  Pose3DMeasurement.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

#if DEBUG
import Foundation
import simd

enum Pose3DIssue: String, Sendable {
    case noBody
    case missingJoint
    case invalidGeometry
    case unsupportedRevision
    case visionError
    case cancelled
}

enum PoseHeightEstimation: String, Sendable {
    case reference
    case measured
    case unknown
}

struct BodyPose3D: Sendable {
    let joints: [BodyJoint: SIMD3<Double>]
    let heightEstimation: PoseHeightEstimation
    let bodyHeight: Double?
    let requestRevision: Int

    init(
        joints: [BodyJoint: SIMD3<Double>], heightEstimation: PoseHeightEstimation = .reference,
        bodyHeight: Double? = nil, requestRevision: Int = 1
    ) {
        self.joints = joints
        self.heightEstimation = heightEstimation
        self.bodyHeight = bodyHeight
        self.requestRevision = requestRevision
    }
}

struct LegMeasurement3D: Sendable, Equatable {
    let angle: Double?
    let hipMinusKneeModelY: Double?
    let normalizedHipOffset: Double?
    let issue: Pose3DIssue?

    var isUsable: Bool { issue == nil && angle != nil }
}

enum SpatialJointGeometry {
    static func angle(first: SIMD3<Double>, vertex: SIMD3<Double>, third: SIMD3<Double>) -> Double? {
        guard isFinite(first), isFinite(vertex), isFinite(third) else { return nil }
        let upperVector = first - vertex
        let lowerVector = third - vertex
        let upperLength = simd_length(upperVector)
        let lowerLength = simd_length(lowerVector)
        guard upperLength.isFinite, lowerLength.isFinite,
              upperLength > 0.000001, lowerLength > 0.000001 else { return nil }
        let cosine = simd_dot(upperVector / upperLength, lowerVector / lowerLength)
        guard cosine.isFinite else { return nil }
        return acos(min(1, max(-1, cosine))) * 180 / .pi
    }

    static func isFinite(_ point: SIMD3<Double>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    static func measure(_ pose: BodyPose3D?, joints: [BodyJoint]) -> LegMeasurement3D {
        guard joints.count == 3,
              let hipPoint = pose?.joints[joints[0]],
              let kneePoint = pose?.joints[joints[1]],
              let anklePoint = pose?.joints[joints[2]] else {
            return LegMeasurement3D(angle: nil, hipMinusKneeModelY: nil, normalizedHipOffset: nil, issue: .missingJoint)
        }
        guard let measuredAngle = angle(first: hipPoint, vertex: kneePoint, third: anklePoint) else {
            return LegMeasurement3D(angle: nil, hipMinusKneeModelY: nil, normalizedHipOffset: nil, issue: .invalidGeometry)
        }
        let femurLength = simd_length(hipPoint - kneePoint)
        return LegMeasurement3D(
            angle: measuredAngle, hipMinusKneeModelY: hipPoint.y - kneePoint.y,
            normalizedHipOffset: (hipPoint.y - kneePoint.y) / femurLength, issue: nil
        )
    }
}

struct ExperimentalDepthAnalysis: Sendable {
    enum Phase: String, Sendable {
        case unavailable
        case measuring
    }

    enum Decision: String, Sendable {
        case rejectedMeasurement
        case indeterminateDepth
    }

    let leftLeg: LegMeasurement3D
    let rightLeg: LegMeasurement3D
    let phase: Phase
    let decision: Decision
    var confirmedRepetitions: Int? { nil }

    init(pose: BodyPose3D?) {
        leftLeg = SpatialJointGeometry.measure(pose, joints: [.leftHip, .leftKnee, .leftAnkle])
        rightLeg = SpatialJointGeometry.measure(pose, joints: [.rightHip, .rightKnee, .rightAnkle])
        let hasMeasurement = leftLeg.isUsable || rightLeg.isUsable
        phase = hasMeasurement ? .measuring : .unavailable
        decision = hasMeasurement ? .indeterminateDepth : .rejectedMeasurement
    }
}
#endif
