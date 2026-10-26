//
//  PoseAnalyzer.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreGraphics
import Foundation

final class PoseAnalyzer {
    private var smoothedAngle: Double?

    func kneeAngle(from pose: BodyPose) -> Double? {
        let candidates: [(BodyJoint, BodyJoint, BodyJoint)] = [
            (.leftHip, .leftKnee, .leftAnkle),
            (.rightHip, .rightKnee, .rightAnkle)
        ]

        for candidate in candidates {
            guard
                let hipPoint = pose.confidentPoint(for: candidate.0),
                let kneePoint = pose.confidentPoint(for: candidate.1),
                let anklePoint = pose.confidentPoint(for: candidate.2),
                let measuredAngle = JointAngleCalculator.angle(
                    first: CGPoint(x: hipPoint.x * pose.aspectRatio, y: hipPoint.y),
                    vertex: CGPoint(x: kneePoint.x * pose.aspectRatio, y: kneePoint.y),
                    third: CGPoint(x: anklePoint.x * pose.aspectRatio, y: anklePoint.y)
                )
            else {
                continue
            }

            let updatedAngle = smoothedAngle.map { 0.35 * measuredAngle + 0.65 * $0 }
                ?? measuredAngle
            smoothedAngle = updatedAngle
            return updatedAngle
        }

        smoothedAngle = nil
        return nil
    }

    func reset() {
        smoothedAngle = nil
    }
}
