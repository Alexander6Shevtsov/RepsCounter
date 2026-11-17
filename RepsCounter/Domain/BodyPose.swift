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

#if DEBUG
struct Vision3DProbe: Sendable {
    let twoDimensionalLatencyMs: Double
    let threeDimensionalLatencyMs: Double?
    let leftKneeAngle: Double?
    let rightKneeAngle: Double?
    let leftHipKneeHeightRatio: Double?
    let rightHipKneeHeightRatio: Double?
    let sampleCount: Int
    let observationAvailable: Bool
}
#endif

struct BodyPose: Sendable {
    let joints: [BodyJoint: JointPoint]
    let aspectRatio: CGFloat
    let rotationAngle: CGFloat
    #if DEBUG
    let vision3DProbe: Vision3DProbe?
    #endif

    init(joints: [BodyJoint: JointPoint], aspectRatio: CGFloat, rotationAngle: CGFloat = 90) {
        self.joints = joints
        self.aspectRatio = aspectRatio
        self.rotationAngle = rotationAngle
        #if DEBUG
        vision3DProbe = nil
        #endif
    }

    #if DEBUG
    init(joints: [BodyJoint: JointPoint], aspectRatio: CGFloat, rotationAngle: CGFloat, vision3DProbe: Vision3DProbe?) {
        self.joints = joints
        self.aspectRatio = aspectRatio
        self.rotationAngle = rotationAngle
        self.vision3DProbe = vision3DProbe
    }
    #endif

    func confidentPoint(for joint: BodyJoint, minimumConfidence: Float = 0.5) -> CGPoint? {
        guard let point = joints[joint], point.confidence >= minimumConfidence else {
            return nil
        }
        return point.location
    }
}
