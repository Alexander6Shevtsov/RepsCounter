//
//  BodyPose.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreGraphics

struct JointPoint: Sendable {
    let location: CGPoint
    let confidence: Float
}

enum BodyJoint: CaseIterable, Hashable, Sendable {
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle
}

struct BodyPose: Sendable {
    let joints: [BodyJoint: JointPoint]
    let aspectRatio: CGFloat

    func confidentPoint(for joint: BodyJoint, minimumConfidence: Float = 0.5) -> CGPoint? {
        guard let point = joints[joint], point.confidence >= minimumConfidence else {
            return nil
        }
        return point.location
    }
}
