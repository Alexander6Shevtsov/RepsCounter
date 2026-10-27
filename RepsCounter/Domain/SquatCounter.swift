//
//  SquatCounter.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import Foundation

enum SquatPhase: Equatable {
    case seekingStanding
    case standing
    case lowered
}

enum SquatDecision: Equatable {
    case awaitingStanding
    case confirmingStanding
    case awaitingStandingSmoothing
    case standingConfirmed
    case awaitingDepth
    case confirmingDepth
    case awaitingDepthSmoothing
    case loweredConfirmed
    case awaitingReturn
    case confirmingReturn
    case awaitingReturnSmoothing
    case repetitionCounted
    case invalidMeasurement
}

struct SquatCounter {
    private(set) var repetitions = 0
    private(set) var phase: SquatPhase = .seekingStanding
    private(set) var consecutiveFrames = 0
    private(set) var decision: SquatDecision = .awaitingStanding
    private var stableFrames = 0

    let standingThreshold: Double
    let loweredThreshold: Double
    let requiredStableFrames: Int

    init(standingThreshold: Double = 160, loweredThreshold: Double = 105, requiredStableFrames: Int = 3) {
        self.standingThreshold = standingThreshold
        self.loweredThreshold = loweredThreshold
        self.requiredStableFrames = max(1, requiredStableFrames)
    }

    mutating func process(angle: Double?) -> Bool {
        process(measuredAngle: angle, smoothedAngle: angle)
    }

    mutating func process(measuredAngle: Double?, smoothedAngle: Double?) -> Bool {
        guard let measuredAngle, let smoothedAngle,
              measuredAngle.isFinite, smoothedAngle.isFinite,
              (0...180).contains(measuredAngle), (0...180).contains(smoothedAngle) else {
            resetMovement()
            decision = .invalidMeasurement
            return false
        }

        switch phase {
        case .seekingStanding:
            let measuredSatisfied = measuredAngle >= standingThreshold
            guard confirm(measured: measuredSatisfied, smoothed: smoothedAngle >= standingThreshold) else {
                if !measuredSatisfied { decision = .awaitingStanding }
                else if consecutiveFrames == requiredStableFrames { decision = .awaitingStandingSmoothing }
                else { decision = .confirmingStanding }
                return false
            }
            phase = .standing
            decision = .standingConfirmed
        case .standing:
            let measuredSatisfied = measuredAngle <= loweredThreshold
            guard confirm(measured: measuredSatisfied, smoothed: smoothedAngle <= loweredThreshold) else {
                if !measuredSatisfied { decision = .awaitingDepth }
                else if consecutiveFrames == requiredStableFrames { decision = .awaitingDepthSmoothing }
                else { decision = .confirmingDepth }
                return false
            }
            phase = .lowered
            decision = .loweredConfirmed
        case .lowered:
            let measuredSatisfied = measuredAngle >= standingThreshold
            guard confirm(measured: measuredSatisfied, smoothed: smoothedAngle >= standingThreshold) else {
                if !measuredSatisfied { decision = .awaitingReturn }
                else if consecutiveFrames == requiredStableFrames { decision = .awaitingReturnSmoothing }
                else { decision = .confirmingReturn }
                return false
            }
            repetitions += 1
            phase = .standing
            decision = .repetitionCounted
            return true
        }
        return false
    }

    mutating func reset() {
        repetitions = 0
        resetMovement()
    }

    mutating func resetMovement() {
        phase = .seekingStanding
        stableFrames = 0
        consecutiveFrames = 0
        decision = .awaitingStanding
    }

    private mutating func confirm(measured: Bool, smoothed: Bool) -> Bool {
        stableFrames = measured ? min(requiredStableFrames, stableFrames + 1) : 0
        consecutiveFrames = stableFrames
        if stableFrames >= requiredStableFrames, smoothed {
            stableFrames = 0
            return true
        }
        return false
    }
}
