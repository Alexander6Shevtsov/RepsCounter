//
//  PoseOverlayView.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import AVFoundation
import UIKit

final class PoseOverlayView: UIView {
    private let skeletonLayer = CAShapeLayer()
    private let jointLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        skeletonLayer.strokeColor = UIColor.systemBlue.cgColor
        skeletonLayer.lineWidth = 2.5
        skeletonLayer.fillColor = UIColor.clear.cgColor
        skeletonLayer.shadowColor = UIColor.systemBlue.cgColor
        skeletonLayer.shadowOpacity = 0.8
        skeletonLayer.shadowRadius = 4
        jointLayer.fillColor = UIColor.white.cgColor
        jointLayer.strokeColor = UIColor.systemBlue.cgColor
        jointLayer.lineWidth = 2
        layer.addSublayer(skeletonLayer)
        layer.addSublayer(jointLayer)
    }

    required init?(coder: NSCoder) { nil }

    func render(_ pose: BodyPose?, previewLayer: AVCaptureVideoPreviewLayer) {
        guard let pose else {
            skeletonLayer.path = nil
            jointLayer.path = nil
            return
        }

        let connections: [(BodyJoint, BodyJoint)] = [
            (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow),
            (.leftElbow, .leftWrist), (.rightShoulder, .rightElbow),
            (.rightElbow, .rightWrist), (.leftShoulder, .leftHip),
            (.rightShoulder, .rightHip), (.leftHip, .rightHip),
            (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
            (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
        ]
        func displayPoint(for joint: BodyJoint) -> CGPoint? {
            guard let point = pose.confidentPoint(for: joint) else { return nil }
            return PoseGeometry.layerPoint(fromVisionPoint: point, rotationAngle: pose.rotationAngle) { capturePoint in
                previewLayer.layerPointConverted(fromCaptureDevicePoint: capturePoint)
            }
        }

        let skeletonPath = UIBezierPath()
        for connection in connections {
            guard let startPoint = displayPoint(for: connection.0),
                  let endPoint = displayPoint(for: connection.1) else { continue }
            skeletonPath.move(to: startPoint)
            skeletonPath.addLine(to: endPoint)
        }
        let jointPath = UIBezierPath()
        for joint in BodyJoint.allCases {
            guard let point = displayPoint(for: joint) else { continue }
            jointPath.append(UIBezierPath(ovalIn: CGRect(
                x: point.x - 4, y: point.y - 4, width: 8, height: 8
            )))
        }
        skeletonLayer.path = skeletonPath.cgPath
        jointLayer.path = jointPath.cgPath
    }
}
