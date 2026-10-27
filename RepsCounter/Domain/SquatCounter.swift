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
    case standingConfirmed
    case awaitingDepth
    case confirmingDepth
    case loweredConfirmed
    case awaitingReturn
    case confirmingReturn
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
        guard let angle, angle.isFinite, (0...180).contains(angle) else {
            resetMovement()
            decision = .invalidMeasurement
            return false
        }

        switch phase {
        case .seekingStanding:
            let satisfied = angle >= standingThreshold
            guard confirm(satisfied) else {
                decision = satisfied ? .confirmingStanding : .awaitingStanding
                return false
            }
            phase = .standing
            decision = .standingConfirmed
        case .standing:
            let satisfied = angle <= loweredThreshold
            guard confirm(satisfied) else {
                decision = satisfied ? .confirmingDepth : .awaitingDepth
                return false
            }
            phase = .lowered
            decision = .loweredConfirmed
        case .lowered:
            let satisfied = angle >= standingThreshold
            guard confirm(satisfied) else {
                decision = satisfied ? .confirmingReturn : .awaitingReturn
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

    private mutating func confirm(_ condition: Bool) -> Bool {
        stableFrames = condition ? stableFrames + 1 : 0
        consecutiveFrames = stableFrames
        if stableFrames >= requiredStableFrames {
            stableFrames = 0
            return true
        }
        return false
    }
}
