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
#if DEBUG
import os
import simd

enum Vision3DGeometry {
    static func metrics(
        hipPosition: SIMD3<Float>,
        kneePosition: SIMD3<Float>,
        anklePosition: SIMD3<Float>
    ) -> (angle: Double, heightRatio: Double)? {
        let thighVector = hipPosition - kneePosition
        let shinVector = anklePosition - kneePosition
        let thighLength = simd_length(thighVector)
        let shinLength = simd_length(shinVector)
        let denominator = thighLength * shinLength
        guard thighLength.isFinite, shinLength.isFinite,
              denominator.isFinite, denominator > 0.000_001 else { return nil }
        let cosine = max(-1.0, min(1.0, Double(simd_dot(thighVector, shinVector) / denominator)))
        let angle = acos(cosine) * 180 / Double.pi
        let heightRatio = Double(thighVector.y / thighLength)
        guard angle.isFinite, heightRatio.isFinite else { return nil }
        return (angle, heightRatio)
    }
}

enum Vision3DProbeControl {
    private static let enabled = OSAllocatedUnfairLock(initialState: false)

    static var isEnabled: Bool {
        enabled.withLock { $0 }
    }

    @discardableResult
    static func toggle() -> Bool {
        enabled.withLock { value in
            value.toggle()
            return value
        }
    }
}
#endif

final class PoseDetector {
    private let request = VNDetectHumanBodyPoseRequest()
    #if DEBUG
    private let threeDimensionalRequest = VNDetectHumanBodyPose3DRequest()
    private var analyzedFrames = 0
    private var threeDimensionalSamples = 0
    private let probeStride = 6
    #endif

    func detect(pixelBuffer: CVPixelBuffer, rotationAngle: CGFloat = 90) -> BodyPose? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: PoseGeometry.visionOrientation, options: [:])
        #if DEBUG
        let detectionStartedAt = ContinuousClock.now
        #endif
        do {
            try handler.perform([request])
            #if DEBUG
            let twoDimensionalLatencyMs = elapsedMilliseconds(since: detectionStartedAt)
            #endif
            guard let observation = request.results?.first else { return nil }

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
            #if DEBUG
            let probe = sampleThreeDimensionalPose(
                handler: handler,
                twoDimensionalLatencyMs: twoDimensionalLatencyMs
            )
            return BodyPose(
                joints: joints,
                aspectRatio: aspectRatio,
                rotationAngle: rotationAngle,
                vision3DProbe: probe
            )
            #else
            return BodyPose(joints: joints, aspectRatio: aspectRatio, rotationAngle: rotationAngle)
            #endif
        } catch {
            return nil
        }
    }

    #if DEBUG
    private func sampleThreeDimensionalPose(
        handler: VNImageRequestHandler,
        twoDimensionalLatencyMs: Double
    ) -> Vision3DProbe {
        analyzedFrames += 1
        guard Vision3DProbeControl.isEnabled,
              analyzedFrames.isMultiple(of: probeStride) else {
            return Vision3DProbe(
                twoDimensionalLatencyMs: twoDimensionalLatencyMs,
                threeDimensionalLatencyMs: nil,
                leftKneeAngle: nil,
                rightKneeAngle: nil,
                leftHipKneeHeightRatio: nil,
                rightHipKneeHeightRatio: nil,
                sampleCount: threeDimensionalSamples,
                observationAvailable: false
            )
        }

        threeDimensionalSamples += 1
        let startedAt = ContinuousClock.now
        let observation: VNHumanBodyPose3DObservation?
        do {
            try handler.perform([threeDimensionalRequest])
            observation = threeDimensionalRequest.results?.first
        } catch {
            observation = nil
        }
        let durationMs = elapsedMilliseconds(since: startedAt)
        let leftMetrics = observation.flatMap {
            threeDimensionalMetrics(in: $0, hip: .leftHip, knee: .leftKnee, ankle: .leftAnkle)
        }
        let rightMetrics = observation.flatMap {
            threeDimensionalMetrics(in: $0, hip: .rightHip, knee: .rightKnee, ankle: .rightAnkle)
        }
        return Vision3DProbe(
            twoDimensionalLatencyMs: twoDimensionalLatencyMs,
            threeDimensionalLatencyMs: durationMs,
            leftKneeAngle: leftMetrics?.angle,
            rightKneeAngle: rightMetrics?.angle,
            leftHipKneeHeightRatio: leftMetrics?.heightRatio,
            rightHipKneeHeightRatio: rightMetrics?.heightRatio,
            sampleCount: threeDimensionalSamples,
            observationAvailable: observation != nil
        )
    }

    private func threeDimensionalMetrics(
        in observation: VNHumanBodyPose3DObservation,
        hip: VNHumanBodyPose3DObservation.JointName,
        knee: VNHumanBodyPose3DObservation.JointName,
        ankle: VNHumanBodyPose3DObservation.JointName
    ) -> (angle: Double, heightRatio: Double)? {
        guard let hipJoint = try? observation.recognizedPoint(hip),
              let kneeJoint = try? observation.recognizedPoint(knee),
              let ankleJoint = try? observation.recognizedPoint(ankle) else { return nil }

        return Vision3DGeometry.metrics(
            hipPosition: translation(hipJoint.position),
            kneePosition: translation(kneeJoint.position),
            anklePosition: translation(ankleJoint.position)
        )
    }

    private func translation(_ matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    private func elapsedMilliseconds(since startedAt: ContinuousClock.Instant) -> Double {
        let components = startedAt.duration(to: ContinuousClock.now).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
    #endif
}
