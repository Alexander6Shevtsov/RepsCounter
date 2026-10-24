import Foundation

enum SquatPhase: Equatable {
    case seekingStanding
    case standing
    case lowered
}

struct SquatCounter {
    private(set) var repetitions = 0
    private(set) var phase: SquatPhase = .seekingStanding
    private var stableFrames = 0
    private var missingFrames = 0

    let standingThreshold: Double
    let loweredThreshold: Double
    let requiredStableFrames: Int

    init(standingThreshold: Double = 160, loweredThreshold: Double = 105, requiredStableFrames: Int = 3) {
        self.standingThreshold = standingThreshold
        self.loweredThreshold = loweredThreshold
        self.requiredStableFrames = max(1, requiredStableFrames)
    }

    mutating func process(angle: Double?) -> Bool {
        guard let angle, angle.isFinite else {
            stableFrames = 0
            missingFrames += 1
            if missingFrames >= 12 {
                phase = .seekingStanding
            }
            return false
        }

        missingFrames = 0
        switch phase {
        case .seekingStanding:
            guard confirm(angle >= standingThreshold) else { return false }
            phase = .standing
        case .standing:
            guard confirm(angle <= loweredThreshold) else { return false }
            phase = .lowered
        case .lowered:
            guard confirm(angle >= standingThreshold) else { return false }
            repetitions += 1
            phase = .standing
            return true
        }
        return false
    }

    mutating func reset() {
        repetitions = 0
        phase = .seekingStanding
        stableFrames = 0
        missingFrames = 0
    }

    private mutating func confirm(_ condition: Bool) -> Bool {
        stableFrames = condition ? stableFrames + 1 : 0
        if stableFrames >= requiredStableFrames {
            stableFrames = 0
            return true
        }
        return false
    }
}
