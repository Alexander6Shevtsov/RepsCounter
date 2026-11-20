//
//  PoseOverlayView.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import AVFoundation
import UIKit

struct PoseOverlayPointTracker {
    private struct TrackedPoint {
        let location: CGPoint
        let observedAt: TimeInterval
    }

    private var trackedPoints: [BodyJoint: TrackedPoint] = [:]
    private var previousTimestamp: TimeInterval?
    private let maximumHoldDuration: TimeInterval = 0.18
    private let currentWeight: CGFloat = 0.7

    mutating func update(_ pose: BodyPose?, at timestamp: TimeInterval) -> [BodyJoint: CGPoint] {
        guard timestamp.isFinite, timestamp >= 0 else {
            reset()
            return [:]
        }
        if let previousTimestamp,
           timestamp < previousTimestamp || timestamp - previousTimestamp > 0.5 {
            trackedPoints.removeAll()
        }
        previousTimestamp = timestamp

        var visiblePoints: [BodyJoint: CGPoint] = [:]
        for joint in BodyJoint.allCases {
            let previous = trackedPoints[joint]
            if let location = pose?.confidentPoint(for: joint),
               location.x.isFinite, location.y.isFinite {
                let smoothed: CGPoint
                if let previous,
                   timestamp - previous.observedAt >= 0,
                   timestamp - previous.observedAt <= maximumHoldDuration {
                    smoothed = CGPoint(
                        x: location.x * currentWeight + previous.location.x * (1 - currentWeight),
                        y: location.y * currentWeight + previous.location.y * (1 - currentWeight)
                    )
                } else {
                    smoothed = location
                }
                trackedPoints[joint] = TrackedPoint(location: smoothed, observedAt: timestamp)
                visiblePoints[joint] = smoothed
            } else if let previous,
                      timestamp - previous.observedAt >= 0,
                      timestamp - previous.observedAt <= maximumHoldDuration {
                visiblePoints[joint] = previous.location
            } else {
                trackedPoints.removeValue(forKey: joint)
            }
        }
        return visiblePoints
    }

    mutating func reset() {
        trackedPoints.removeAll()
        previousTimestamp = nil
    }
}

final class PoseOverlayView: UIView {
    private static let connections: [(BodyJoint, BodyJoint)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist), (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist), (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip), (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
    ]

    private let skeletonLayer = CAShapeLayer()
    private let jointLayer = CAShapeLayer()
    private var pointTracker = PoseOverlayPointTracker()
    private var visiblePoints: [BodyJoint: CGPoint] = [:]
    private var lastRotationAngle: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        skeletonLayer.strokeColor = UIColor.systemBlue.cgColor
        skeletonLayer.lineWidth = 2
        skeletonLayer.lineCap = .round
        skeletonLayer.lineJoin = .round
        skeletonLayer.fillColor = UIColor.clear.cgColor
        skeletonLayer.shadowColor = UIColor.systemBlue.cgColor
        skeletonLayer.shadowOpacity = 0.5
        skeletonLayer.shadowRadius = 3
        jointLayer.fillColor = UIColor.white.cgColor
        jointLayer.strokeColor = UIColor.systemBlue.cgColor
        jointLayer.lineWidth = 2
        layer.addSublayer(skeletonLayer)
        layer.addSublayer(jointLayer)
    }

    required init?(coder: NSCoder) { nil }

    func render(
        _ pose: BodyPose?,
        previewLayer: AVCaptureVideoPreviewLayer,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        if let rotationAngle = pose?.rotationAngle,
           let lastRotationAngle,
           rotationAngle != lastRotationAngle {
            reset()
        }
        if let rotationAngle = pose?.rotationAngle {
            lastRotationAngle = rotationAngle
        }
        visiblePoints = pointTracker.update(pose, at: timestamp)
        redraw(previewLayer: previewLayer)
    }

    func redraw(previewLayer: AVCaptureVideoPreviewLayer) {
        let rotationAngle = lastRotationAngle ?? 90
        var convertedPoints: [BodyJoint: CGPoint] = [:]
        for (joint, location) in visiblePoints {
            convertedPoints[joint] = PoseGeometry.layerPoint(
                fromVisionPoint: location,
                rotationAngle: rotationAngle
            ) { capturePoint in
                previewLayer.layerPointConverted(fromCaptureDevicePoint: capturePoint)
            }
        }

        let skeletonPath = UIBezierPath()
        for (startJoint, endJoint) in Self.connections {
            guard let startPoint = convertedPoints[startJoint],
                  let endPoint = convertedPoints[endJoint] else { continue }
            skeletonPath.move(to: startPoint)
            skeletonPath.addLine(to: endPoint)
        }
        let jointPath = UIBezierPath()
        for point in convertedPoints.values {
            jointPath.append(UIBezierPath(
                ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            ))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        skeletonLayer.path = skeletonPath.cgPath
        jointLayer.path = jointPath.cgPath
        CATransaction.commit()
    }

    func reset() {
        pointTracker.reset()
        visiblePoints.removeAll()
        lastRotationAngle = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        skeletonLayer.path = nil
        jointLayer.path = nil
        CATransaction.commit()
    }
}
