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

struct Vision3DRateMeter {
    private var samples: [ContinuousClock.Instant] = []
    private let maximumSamples = 20

    mutating func record(at timestamp: ContinuousClock.Instant) {
        samples.append(timestamp)
        if samples.count > maximumSamples {
            samples.removeFirst()
        }
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    var framesPerSecond: Double? {
        guard samples.count > 1,
              let firstTimestamp = samples.first,
              let lastTimestamp = samples.last else { return nil }
        let components = firstTimestamp.duration(to: lastTimestamp).components
        let elapsedSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard elapsedSeconds > 0 else { return nil }
        return Double(samples.count - 1) / elapsedSeconds
    }
}

struct Vision3DSamplingController {
    private var twoDimensionalRate = Vision3DRateMeter()
    private var threeDimensionalRate = Vision3DRateMeter()
    private var lastSampleTime: ContinuousClock.Instant?
    private var lastThreeDimensionalLatencyMs = 0.0
    private(set) var sampleCount = 0

    var twoDimensionalFramesPerSecond: Double? { twoDimensionalRate.framesPerSecond }
    var threeDimensionalSamplesPerSecond: Double? { threeDimensionalRate.framesPerSecond }

    mutating func recordTwoDimensionalFrame(at timestamp: ContinuousClock.Instant) {
        twoDimensionalRate.record(at: timestamp)
    }

    mutating func shouldSampleThreeDimensional(
        at timestamp: ContinuousClock.Instant,
        enabled: Bool
    ) -> Bool {
        guard enabled else {
            clearThreeDimensionalHistory()
            return false
        }
        let intervalMilliseconds = Int(ceil(max(125, lastThreeDimensionalLatencyMs * 2)))
        if let lastSampleTime,
           lastSampleTime.duration(to: timestamp) < .milliseconds(intervalMilliseconds) {
            return false
        }
        lastSampleTime = timestamp
        return true
    }

    mutating func recordThreeDimensionalSample(
        at timestamp: ContinuousClock.Instant,
        latencyMilliseconds: Double
    ) {
        sampleCount += 1
        lastThreeDimensionalLatencyMs = max(0, latencyMilliseconds)
        threeDimensionalRate.record(at: timestamp)
    }

    private mutating func clearThreeDimensionalHistory() {
        lastSampleTime = nil
        lastThreeDimensionalLatencyMs = 0
        sampleCount = 0
        threeDimensionalRate.reset()
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
    private var samplingController = Vision3DSamplingController()
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
            samplingController.recordTwoDimensionalFrame(at: detectionStartedAt)
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
        let startedAt = ContinuousClock.now
        guard samplingController.shouldSampleThreeDimensional(
            at: startedAt,
            enabled: Vision3DProbeControl.isEnabled
        ) else {
            return Vision3DProbe(
                twoDimensionalLatencyMs: twoDimensionalLatencyMs,
                threeDimensionalLatencyMs: nil,
                leftKneeAngle: nil,
                rightKneeAngle: nil,
                leftHipKneeHeightRatio: nil,
                rightHipKneeHeightRatio: nil,
                sampleCount: samplingController.sampleCount,
                observationAvailable: false,
                twoDimensionalFramesPerSecond: samplingController.twoDimensionalFramesPerSecond,
                threeDimensionalSamplesPerSecond: samplingController.threeDimensionalSamplesPerSecond
            )
        }
        let observation: VNHumanBodyPose3DObservation?
        do {
            try handler.perform([threeDimensionalRequest])
            observation = threeDimensionalRequest.results?.first
        } catch {
            observation = nil
        }
        let durationMs = elapsedMilliseconds(since: startedAt)
        samplingController.recordThreeDimensionalSample(
            at: startedAt,
            latencyMilliseconds: durationMs
        )
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
            sampleCount: samplingController.sampleCount,
            observationAvailable: observation != nil,
            twoDimensionalFramesPerSecond: samplingController.twoDimensionalFramesPerSecond,
            threeDimensionalSamplesPerSecond: samplingController.threeDimensionalSamplesPerSecond
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
