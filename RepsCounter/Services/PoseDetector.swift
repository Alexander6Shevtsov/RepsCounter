//
//  PoseDetector.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import Foundation
import CoreVideo
import ImageIO
import CoreGraphics
import Vision

final class PoseDetector {
    private let request = VNDetectHumanBodyPoseRequest()

    func detect(pixelBuffer: CVPixelBuffer, rotationAngle: CGFloat = 90, trace: PipelineTelemetry.Frame? = nil) -> BodyPose? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: PoseGeometry.visionOrientation, options: [:])
        #if DEBUG
        var qualityJoints: [BodyJoint: JointPoint] = [:]
        defer {
            if let trace {
                let config = CameraQualitySelection.current
                let build = CameraQualitySelection.build
                let quality = PipelineTelemetry.CameraQuality(
                    width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
                    requestedResolution: config.resolution.rawValue, targetVisionHz: config.visionRate.rawValue,
                    rotationAngle: Double(rotationAngle), mirrored: false, orientation: "up",
                    confidences: Dictionary(uniqueKeysWithValues: qualityJoints.map {
                        (String(describing: $0.key), $0.value.confidence.isFinite ? $0.value.confidence : 0)
                    }), buildSHA: build.sha, sourceState: build.state, patchSHA: build.patch,
                    previewMirrored: trace.identity.camera == "front", regionOfInterest: "0,0,1,1")
                trace.recorder.record(.cameraQuality, frame: trace.identity, cameraQuality: quality)
            }

        }
        #endif
        do {
            let requestStart = trace?.mark(.visionRequestStart)
            do {
                defer { trace?.mark(.visionRequestEnd, since: requestStart) }
                try handler.perform([request])
            }
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
            #if DEBUG
            qualityJoints = joints
            #endif
            let aspectRatio = PoseGeometry.aspectRatio(pixelBuffer: pixelBuffer)

            trace?.mark(.visionPose)
            return BodyPose(joints: joints, aspectRatio: aspectRatio, rotationAngle: rotationAngle)
        } catch {
            trace?.mark(.visionError, reason: "\((error as NSError).domain)/\((error as NSError).code)")
            return nil
        }
    }
}
