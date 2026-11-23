//
//  PoseAnalyzer.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreGraphics
import Foundation

enum BodyLeg: Equatable {
    case left
    case right
}

enum LegMeasurementIssue: Equatable {
    case missingJoint
    case lowConfidence
    case invalidGeometry
}

struct LegMeasurement: Equatable {
    let angle: Double?
    let hipConfidence: Float?
    let kneeConfidence: Float?
    let ankleConfidence: Float?
    let issue: LegMeasurementIssue?

    var isReliable: Bool { issue == nil && angle != nil }

    var confidence: Float {
        min(hipConfidence ?? 0, kneeConfidence ?? 0, ankleConfidence ?? 0)
    }
}

struct PoseAnalysis {
    let leftMeasurement: LegMeasurement
    let rightMeasurement: LegMeasurement
    let selectedLeg: BodyLeg?
    let measuredAngle: Double?
    let smoothedAngle: Double?
    let hipKneeHeightRatio: Double?
    let requiresMovementReset: Bool
    let didSwitchLeg: Bool
}

final class PoseAnalyzer {
    private var smoothedAngle: Double?
    private var selectedLeg: BodyLeg?
    private var alternateStandingLeg: BodyLeg?
    private var alternateStandingFrames = 0
    private let requiredAlternateStandingFrames = 3
    private let standingThreshold: Double = 160

    func analyze(_ pose: BodyPose?) -> PoseAnalysis {
        let leftMeasurement = measure(pose, joints: [.leftHip, .leftKnee, .leftAnkle])
        let rightMeasurement = measure(pose, joints: [.rightHip, .rightKnee, .rightAnkle])
        let previousLeg = selectedLeg
        let nextLeg = chooseLeg(left: leftMeasurement, right: rightMeasurement)
        let didSwitchLeg = previousLeg != nil && nextLeg != nil && nextLeg != previousLeg
        let requiresReset = nextLeg == nil || didSwitchLeg
        if didSwitchLeg || nextLeg == nil { smoothedAngle = nil }
        if let nextLeg { selectedLeg = nextLeg }
        let measuredAngle: Double?
        switch nextLeg {
        case .left: measuredAngle = leftMeasurement.angle
        case .right: measuredAngle = rightMeasurement.angle
        case nil: measuredAngle = nil
        }
        if let measuredAngle {
            smoothedAngle = smoothedAngle.map { 0.35 * measuredAngle + 0.65 * $0 } ?? measuredAngle
        }
        let hipKneeHeightRatio = measureHipKneeHeight(pose, selectedLeg: nextLeg)
        return PoseAnalysis(
            leftMeasurement: leftMeasurement,
            rightMeasurement: rightMeasurement,
            selectedLeg: nextLeg,
            measuredAngle: measuredAngle,
            smoothedAngle: smoothedAngle,
            hipKneeHeightRatio: hipKneeHeightRatio,
            requiresMovementReset: requiresReset,
            didSwitchLeg: didSwitchLeg
        )
    }

    func reset() {
        smoothedAngle = nil
        selectedLeg = nil
        clearAlternateStanding()
    }

    private func chooseLeg(left: LegMeasurement, right: LegMeasurement) -> BodyLeg? {
        guard let selectedLeg else {
            if left.isReliable, right.isReliable {
                return left.confidence >= right.confidence ? .left : .right
            }
            if left.isReliable { return .left }
            if right.isReliable { return .right }
            return nil
        }

        let currentMeasurement = selectedLeg == .left ? left : right
        if currentMeasurement.isReliable {
            clearAlternateStanding()
            return selectedLeg
        }

        let otherLeg: BodyLeg = selectedLeg == .left ? .right : .left
        let otherMeasurement = otherLeg == .left ? left : right
        guard otherMeasurement.isReliable,
              let otherAngle = otherMeasurement.angle,
              otherAngle >= standingThreshold else {
            clearAlternateStanding()
            return nil
        }

        if alternateStandingLeg == otherLeg {
            alternateStandingFrames += 1
        } else {
            alternateStandingLeg = otherLeg
            alternateStandingFrames = 1
        }
        guard alternateStandingFrames >= requiredAlternateStandingFrames else { return nil }
        clearAlternateStanding()
        return otherLeg
    }

    private func clearAlternateStanding() {
        alternateStandingLeg = nil
        alternateStandingFrames = 0
    }

    private func measureHipKneeHeight(_ pose: BodyPose?, selectedLeg: BodyLeg?) -> Double? {
        guard let pose, let selectedLeg, pose.aspectRatio.isFinite, pose.aspectRatio > 0 else { return nil }
        let hipJoint: BodyJoint
        let kneeJoint: BodyJoint
        switch selectedLeg {
        case .left:
            hipJoint = .leftHip
            kneeJoint = .leftKnee
        case .right:
            hipJoint = .rightHip
            kneeJoint = .rightKnee
        }
        guard let hipPoint = pose.joints[hipJoint], let kneePoint = pose.joints[kneeJoint] else { return nil }
        let horizontalDifference = Double(hipPoint.location.x - kneePoint.location.x) * Double(pose.aspectRatio)
        let verticalDifference = Double(hipPoint.location.y - kneePoint.location.y)
        guard horizontalDifference.isFinite, verticalDifference.isFinite else { return nil }
        let projectedThighLength = hypot(horizontalDifference, verticalDifference)
        guard projectedThighLength.isFinite, projectedThighLength > 0.000_001 else { return nil }
        let heightRatio = verticalDifference / projectedThighLength
        return heightRatio.isFinite ? heightRatio : nil
    }

    private func measure(_ pose: BodyPose?, joints: [BodyJoint]) -> LegMeasurement {
        let hipPoint = pose?.joints[joints[0]]
        let kneePoint = pose?.joints[joints[1]]
        let anklePoint = pose?.joints[joints[2]]
        var measuredAngle: Double?
        let issue: LegMeasurementIssue?
        if let pose, let hipPoint, let kneePoint, let anklePoint {
            if pose.aspectRatio.isFinite, pose.aspectRatio > 0 {
                measuredAngle = JointAngleCalculator.angle(
                    first: CGPoint(x: hipPoint.location.x * pose.aspectRatio, y: hipPoint.location.y),
                    vertex: CGPoint(x: kneePoint.location.x * pose.aspectRatio, y: kneePoint.location.y),
                    third: CGPoint(x: anklePoint.location.x * pose.aspectRatio, y: anklePoint.location.y)
                )
            }
            let confidences = [hipPoint.confidence, kneePoint.confidence, anklePoint.confidence]
            if confidences.contains(where: { !$0.isFinite || $0 < 0.5 || $0 > 1 }) {
                issue = .lowConfidence
            } else {
                issue = measuredAngle == nil ? .invalidGeometry : nil
            }
        } else {
            issue = .missingJoint
        }
        return LegMeasurement(
            angle: measuredAngle,
            hipConfidence: hipPoint?.confidence,
            kneeConfidence: kneePoint?.confidence,
            ankleConfidence: anklePoint?.confidence,
            issue: issue
        )
    }
}
