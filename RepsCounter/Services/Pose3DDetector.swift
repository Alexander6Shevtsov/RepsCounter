//
//  Pose3DDetector.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

#if DEBUG
import CoreMedia
import ImageIO
import Vision
import os

protocol Pose3DDetecting: Sendable {
    func detect(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) -> Pose3DDetection
    func cancel()
}

final class Pose3DDetector: Pose3DDetecting {
    private struct RequestState {
        var request: VNDetectHumanBodyPose3DRequest?
        var isCancelled = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: RequestState())

    func detect(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) -> Pose3DDetection {
        guard !state.withLock({ $0.isCancelled }) else {
            return Pose3DDetection(pose: nil, issue: .cancelled, detail: nil)
        }
        let request = VNDetectHumanBodyPose3DRequest()
        request.preferBackgroundProcessing = true
        guard VNDetectHumanBodyPose3DRequest.supportedRevisions.contains(request.revision) else {
            return Pose3DDetection(
                pose: nil, issue: .unsupportedRevision,
                detail: "Vision 3D revision \(request.revision) unavailable; supported: \(VNDetectHumanBodyPose3DRequest.supportedRevisions)"
            )
        }
        do {
            _ = try request.supportedJointNames
            let registered = state.withLockUnchecked { current in
                guard !current.isCancelled else { return false }
                current.request = request
                return true
            }
            guard registered else { return Pose3DDetection(pose: nil, issue: .cancelled, detail: nil) }
            defer { state.withLock { $0.request = nil } }
            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: orientation, options: [:])
            try handler.perform([request])
            let observation = state.withLockUnchecked { current in
                current.request = nil
                return current.isCancelled ? nil : request.results?.first
            }
            guard !state.withLock({ $0.isCancelled }) else {
                return Pose3DDetection(pose: nil, issue: .cancelled, detail: nil)
            }
            guard let observation else {
                return Pose3DDetection(pose: nil, issue: .noBody, detail: nil)
            }
            let mappings: [(BodyJoint, VNHumanBodyPose3DObservation.JointName)] = [
                (.leftHip, .leftHip), (.rightHip, .rightHip),
                (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
                (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
            ]
            var joints: [BodyJoint: SIMD3<Double>] = [:]
            for mapping in mappings {
                guard let point = try? observation.recognizedPoint(mapping.1) else { continue }
                let translation = point.position.columns.3
                joints[mapping.0] = SIMD3(Double(translation.x), Double(translation.y), Double(translation.z))
            }
            let estimation: PoseHeightEstimation
            switch observation.heightEstimation {
            case .reference: estimation = .reference
            case .measured: estimation = .measured
            @unknown default: estimation = .unknown
            }
            let height = Double(observation.bodyHeight)
            let pose = BodyPose3D(
                joints: joints, heightEstimation: estimation,
                bodyHeight: height.isFinite && height > 0 ? height : nil, requestRevision: Int(request.revision)
            )
            return Pose3DDetection(pose: pose, issue: nil, detail: nil)
        } catch {
            let cancelled = state.withLock { $0.isCancelled }
            return Pose3DDetection(pose: nil, issue: cancelled ? .cancelled : .visionError, detail: error.localizedDescription)
        }
    }

    func cancel() {
        state.withLockUnchecked { current in
            current.isCancelled = true
            current.request?.cancel()
        }
    }
}
#endif
