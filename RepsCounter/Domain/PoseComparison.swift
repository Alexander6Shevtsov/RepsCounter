//
//  PoseComparison.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

#if DEBUG
import CoreGraphics
import Foundation

struct ExperimentFrameIdentity: Sendable, Hashable {
    let generation: UInt64
    let sequence: UInt64
}

struct ExperimentFrameMetadata: Sendable {
    let identity: ExperimentFrameIdentity
    let timestamp: Double
    let receivedAt: ContinuousClock.Instant
    let position: CameraPosition
    let rotationAngle: CGFloat
    let orientation: UInt32
    let inputMirrored: Bool
    let depthDataProvided: Bool
}

struct Experimental2DAnalysis: Sendable {
    let leftAngle: Double?
    let rightAngle: Double?
    let leftUsable: Bool
    let rightUsable: Bool
    let phase: String
    let decision: String
    let repetitions: Int
}

struct ExperimentFrame2D: Sendable {
    let epoch: UInt64
    let metadata: ExperimentFrameMetadata
    let analysis: Experimental2DAnalysis
    let latency: Double
}

struct Pose3DDetection: Sendable {
    let pose: BodyPose3D?
    let issue: Pose3DIssue?
    let detail: String?
}

struct PoseComparisonPair: Sendable {
    let source: ExperimentFrame2D
    let detection: Pose3DDetection
    let spatial: ExperimentalDepthAnalysis
    let latency: Double
    let completedAt: ContinuousClock.Instant
    var totalLatency: Double { source.metadata.receivedAt.duration(to: completedAt).experimentSeconds }
    var isComparable: Bool {
        (source.analysis.leftUsable && spatial.leftLeg.isUsable)
            || (source.analysis.rightUsable && spatial.rightLeg.isUsable)
    }
}

struct ExperimentLoadStatistics: Sendable, Equatable {
    var sourceFrames = 0
    var analyzed2D = 0
    var admitted3D = 0
    var completed3D = 0
    var comparablePairs = 0
    var usable2D = 0
    var usable3D = 0
    var rateLimited = 0
    var busyDropped = 0
    var captureDropped = 0
    var staleDropped = 0
    var cancelled = 0
    var deliveryDropped = 0
    var invalidInput = 0
    var timeouts = 0

    var skipped3D: Int { rateLimited + busyDropped + staleDropped + cancelled }
    var coverage: Double { analyzed2D > 0 ? Double(comparablePairs) / Double(analyzed2D) : 0 }
}

enum PoseExperimentUpdate: Sendable {
    case planar(ExperimentFrame2D, ExperimentLoadStatistics)
    case paired(PoseComparisonPair, ExperimentLoadStatistics)
}

struct ExperimentAdmission {
    enum Rejection: Equatable {
        case disabled
        case busy
        case rateLimited
    }

    private(set) var epoch: UInt64 = 0
    private(set) var isEnabled = false
    private(set) var isBusy = false
    private var lastAdmission: ContinuousClock.Instant?
    let minimumInterval: Duration

    init(minimumInterval: Duration = .milliseconds(200)) {
        self.minimumInterval = minimumInterval
    }

    mutating func setEnabled(_ enabled: Bool) {
        epoch += 1
        isEnabled = enabled
        lastAdmission = nil
    }

    mutating func admit(at instant: ContinuousClock.Instant) -> Rejection? {
        guard isEnabled else { return .disabled }
        guard !isBusy else { return .busy }
        if let lastAdmission, lastAdmission.duration(to: instant) < minimumInterval { return .rateLimited }
        lastAdmission = instant
        isBusy = true
        return nil
    }

    mutating func complete(epoch completedEpoch: UInt64) -> Bool {
        isBusy = false
        return isEnabled && epoch == completedEpoch
    }
}

struct ExperimentManualAnnotation: Equatable {
    let fullRepetitions: Int
    let partialRepetitions: Int
    let uncertainRepetitions: Int
}

enum ExperimentViewpoint: String, CaseIterable {
    case unspecified
    case frontal
    case diagonal
    case side
}

struct ExperimentSeries {
    let id: UUID
    let startedAt: ContinuousClock.Instant
    var endedAt: ContinuousClock.Instant?
    var annotation: ExperimentManualAnnotation?
    var viewpoint: ExperimentViewpoint = .unspecified
    var productionStartCount = 0
    var productionEndCount: Int?
    var finalStatistics: ExperimentLoadStatistics?
    var pairs: [PoseComparisonPair] = []
    var evictedPairs = 0
}

extension Duration {
    var experimentSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
#endif
