//
//  PoseDetector.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreVideo
import ImageIO
import CoreGraphics
import Vision

final class PoseDetector {
    private let request = VNDetectHumanBodyPoseRequest()

    func detect(pixelBuffer: CVPixelBuffer, rotationAngle: CGFloat = 90, trace: PipelineTelemetry.Frame? = nil) -> BodyPose? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: PoseGeometry.visionOrientation, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else {
                trace?.mark(.noPose)
                return nil
            }

            let mappings: [(BodyJoint, VNHumanBodyPoseObservation.JointName)] = [
                (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
                (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
                (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
                (.leftHip, .leftHip), (.rightHip, .rightHip),
                (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
                (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
            ]

            var joints: [BodyJoint: JointPoint] = [:]
            for mapping in mappings {
                guard let recognizedPoint = try? observation.recognizedPoint(mapping.1) else {
                    continue
                }
                joints[mapping.0] = JointPoint(
                    location: recognizedPoint.location,
                    confidence: recognizedPoint.confidence
                )
            }
            let aspectRatio = PoseGeometry.aspectRatio(pixelBuffer: pixelBuffer)
            trace?.mark(.visionPose)
            return BodyPose(joints: joints, aspectRatio: aspectRatio, rotationAngle: rotationAngle)
        } catch {
            trace?.mark(.visionError, reason: "\((error as NSError).domain)/\((error as NSError).code)")
            return nil
        }
    }
}
