//
//  WorkoutViewModel.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import Foundation

enum WorkoutSaveState: Equatable {
    case notSaved
    case saving
    case saved
    case failed(String)
}

struct WorkoutViewState {
    let repetitions: Int
    let totalRepetitions: Int
    let currentSet: Int
    let targetSets: Int
    let targetRepetitions: Int
    let elapsedSeconds: Int
    let remainingRestSeconds: Int
    let isResting: Bool
    let isPaused: Bool
    let hasStarted: Bool
    let isFinished: Bool
    let poseDetected: Bool
    let saveState: WorkoutSaveState
}

#if DEBUG
enum SquatTrackingStatus: Equatable {
    case waitingForCamera
    case ready
    case tracking
    case paused
    case resting
    case finished
}

enum SquatTrackingReset: Equatable {
    case measurementLost
    case legChanged
    case observationGap
}

struct Vision3DSynchronizedPair {
    let sampleNumber: Int
    let selectedLeg: BodyLeg?
    let twoDimensionalLeftAngle: Double?
    let twoDimensionalRightAngle: Double?
    let twoDimensionalSelectedHeightRatio: Double?
    let probe: Vision3DProbe
}

enum Vision3DStandingAgreement: Equatable {
    case awaitingSelectedLeg
    case awaitingStandingReference
    case insufficientTwoDimensionalData
    case insufficientThreeDimensionalData
    case bothStanding
    case bothMoving
    case twoDimensionalStandingOnly
    case threeDimensionalStandingOnly
}

struct Vision3DReturnShadow {
    private(set) var agreement: Vision3DStandingAgreement = .awaitingSelectedLeg
    private(set) var selectedLeg: BodyLeg?
    private(set) var sampleNumber = 0
    private(set) var twoDimensionalAngle: Double?
    private(set) var threeDimensionalAngle: Double?
    private(set) var twoDimensionalHipKneeRatio: Double?
    private(set) var threeDimensionalHipKneeRatio: Double?
    private(set) var standingReference: Double?
    private(set) var angleDifference: Double?
    private(set) var consecutiveDisagreements = 0
    private(set) var isStableDisagreement = false
    private(set) var stableDisagreementEvents = 0

    let twoDimensionalStandingAngle = 160.0
    let minimumTwoDimensionalStandingRatio = 0.70
    let threeDimensionalStandingAngle = 135.0
    let maximumThreeDimensionalHeightDrop = 0.20
    let minimumConfirmationDuration: TimeInterval = 0.12
    let maximumSampleGap: TimeInterval = 0.75

    private var disagreementStartedAt: TimeInterval?
    private var lastSampleTime: TimeInterval?

    mutating func observe(
        _ probe: Vision3DProbe,
        at timestamp: TimeInterval,
        threeDimensionalLeg: BodyLeg?,
        standingReference: Double?,
        twoDimensionalLeg: BodyLeg?,
        twoDimensionalLeftAngle: Double?,
        twoDimensionalRightAngle: Double?,
        twoDimensionalSelectedHipKneeRatio: Double?
    ) {
        guard probe.threeDimensionalLatencyMs != nil, timestamp.isFinite else { return }
        if let lastSampleTime, timestamp <= lastSampleTime { return }
        if let lastSampleTime, timestamp - lastSampleTime > maximumSampleGap {
            reset()
        }
        if selectedLeg != threeDimensionalLeg {
            reset()
        }
        lastSampleTime = timestamp
        selectedLeg = threeDimensionalLeg
        sampleNumber = probe.sampleCount
        self.standingReference = standingReference

        guard let threeDimensionalLeg else {
            agreement = .awaitingSelectedLeg
            return
        }
        let currentTwoDimensionalAngle = threeDimensionalLeg == .left
            ? twoDimensionalLeftAngle : twoDimensionalRightAngle
        let currentThreeDimensionalAngle = threeDimensionalLeg == .left
            ? probe.leftKneeAngle : probe.rightKneeAngle
        let currentThreeDimensionalRatio = threeDimensionalLeg == .left
            ? probe.leftHipKneeHeightRatio : probe.rightHipKneeHeightRatio
        let currentTwoDimensionalRatio = twoDimensionalLeg == threeDimensionalLeg
            ? twoDimensionalSelectedHipKneeRatio : nil

        twoDimensionalAngle = validatedAngle(currentTwoDimensionalAngle)
        threeDimensionalAngle = validatedAngle(currentThreeDimensionalAngle)
        twoDimensionalHipKneeRatio = validatedRatio(currentTwoDimensionalRatio)
        threeDimensionalHipKneeRatio = validatedRatio(currentThreeDimensionalRatio)
        angleDifference = nil
        if let twoDimensionalAngle, let threeDimensionalAngle {
            angleDifference = twoDimensionalAngle - threeDimensionalAngle
        }

        guard let standingReference = validatedRatio(standingReference) else {
            updateAgreement(.awaitingStandingReference, at: timestamp)
            return
        }
        guard let threeDimensionalAngle, let threeDimensionalHipKneeRatio else {
            updateAgreement(.insufficientThreeDimensionalData, at: timestamp)
            return
        }
        guard let twoDimensionalAngle, let twoDimensionalHipKneeRatio else {
            updateAgreement(.insufficientTwoDimensionalData, at: timestamp)
            return
        }

        let twoDimensionalStanding = twoDimensionalAngle >= twoDimensionalStandingAngle
            && twoDimensionalHipKneeRatio >= minimumTwoDimensionalStandingRatio
        let threeDimensionalStanding = threeDimensionalAngle >= threeDimensionalStandingAngle
            && threeDimensionalHipKneeRatio >= standingReference - maximumThreeDimensionalHeightDrop
        let nextAgreement: Vision3DStandingAgreement
        switch (twoDimensionalStanding, threeDimensionalStanding) {
        case (true, true): nextAgreement = .bothStanding
        case (false, false): nextAgreement = .bothMoving
        case (true, false): nextAgreement = .twoDimensionalStandingOnly
        case (false, true): nextAgreement = .threeDimensionalStandingOnly
        }
        updateAgreement(nextAgreement, at: timestamp)
    }

    mutating func expire(at timestamp: TimeInterval) {
        guard timestamp.isFinite, let lastSampleTime,
              timestamp - lastSampleTime > maximumSampleGap else { return }
        reset()
    }

    mutating func reset() {
        agreement = .awaitingSelectedLeg
        selectedLeg = nil
        sampleNumber = 0
        twoDimensionalAngle = nil
        threeDimensionalAngle = nil
        twoDimensionalHipKneeRatio = nil
        threeDimensionalHipKneeRatio = nil
        standingReference = nil
        angleDifference = nil
        consecutiveDisagreements = 0
        isStableDisagreement = false
        disagreementStartedAt = nil
        lastSampleTime = nil
        stableDisagreementEvents = 0
    }

    private mutating func updateAgreement(
        _ nextAgreement: Vision3DStandingAgreement,
        at timestamp: TimeInterval
    ) {
        agreement = nextAgreement
        guard nextAgreement == .twoDimensionalStandingOnly else {
            consecutiveDisagreements = 0
            isStableDisagreement = false
            disagreementStartedAt = nil
            return
        }
        if disagreementStartedAt == nil {
            disagreementStartedAt = timestamp
        }
        consecutiveDisagreements += 1
        let confirmed = consecutiveDisagreements >= 2
            && timestamp - (disagreementStartedAt ?? timestamp) >= minimumConfirmationDuration
        if confirmed, !isStableDisagreement {
            stableDisagreementEvents += 1
        }
        isStableDisagreement = confirmed
    }

    private func validatedAngle(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...180).contains(value) else { return nil }
        return value
    }

    private func validatedRatio(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (-1...1).contains(value) else { return nil }
        return value
    }
}

struct SquatDiagnostics {
    let analysis: PoseAnalysis?
    let phase: SquatPhase
    let decision: SquatDecision
    let consecutiveFrames: Int
    let requiredFrames: Int
    let standingThreshold: Double
    let loweredThreshold: Double
    let status: SquatTrackingStatus
    let resetReason: SquatTrackingReset?
    let measurementLossCount: Int
    let legChangeCount: Int
    let observationGapCount: Int
    let latestMeasurementIssue: LegMeasurementIssue?
    let activeDepthAttempt: SquatDepthAttempt?
    let lastDepthAttempt: SquatDepthAttempt?
    let recentDepthAttempts: [SquatDepthAttempt]
    let vision2DLatencyMs: Double?
    let vision3DProbe: Vision3DProbe?
    let vision3DSynchronizedPair: Vision3DSynchronizedPair?
    let vision3DExperimentalCounter: Vision3DExperimentalCounter
    let vision3DReturnShadow: Vision3DReturnShadow
}

enum SquatDepthBreak: Equatable {
    case kneeAngle
    case hipHeight
    case invalidMeasurement
    case measurementLost
    case legChanged
    case observationGap
}

enum SquatDepthOutcome: Equatable {
    case counted
    case returnedWithoutDepth
    case invalidMeasurement
    case measurementLost
    case legChanged
    case observationGap
    case paused
    case cameraUnavailable
    case finished
    case trackingReset
}

struct SquatDepthAttempt: Equatable {
    let number: Int
    let selectedLeg: BodyLeg?
    var minRawAngle: Double?
    var minSmoothedAngle: Double?
    var minHipKneeHeightRatio: Double?
    var maxDepthFrames = 0
    var depthBreakCount = 0
    var lastBreak: SquatDepthBreak?
    var maxPoseInterval: TimeInterval?
    var depthConfirmed = false
    var outcome: SquatDepthOutcome?
}

struct SquatDepthAttemptTracker {
    private(set) var activeAttempt: SquatDepthAttempt?
    private(set) var lastAttempt: SquatDepthAttempt?
    private(set) var recentAttempts: [SquatDepthAttempt] = []
    private var nextAttemptNumber = 1
    private var returnStandingFrames = 0
    private var previousPoseTimestamp: TimeInterval?
    private var latestPoseInterval: TimeInterval?

    mutating func recordPose(at timestamp: TimeInterval) {
        if let previousPoseTimestamp, timestamp.isFinite, timestamp >= previousPoseTimestamp {
            latestPoseInterval = timestamp - previousPoseTimestamp
        } else {
            latestPoseInterval = nil
        }
        self.previousPoseTimestamp = timestamp.isFinite ? timestamp : nil
    }

    mutating func resetPoseClock() {
        previousPoseTimestamp = nil
        latestPoseInterval = nil
    }

    mutating func observe(
        analysis: PoseAnalysis,
        phaseBefore: SquatPhase,
        phaseAfter: SquatPhase,
        framesBefore: Int,
        framesAfter: Int,
        decision: SquatDecision,
        counted: Bool,
        standingThreshold: Double
    ) {
        if activeAttempt == nil,
           phaseBefore == .standing,
           let rawAngle = analysis.measuredAngle,
           rawAngle.isFinite,
           rawAngle < standingThreshold {
            activeAttempt = SquatDepthAttempt(number: nextAttemptNumber, selectedLeg: analysis.selectedLeg)
            nextAttemptNumber += 1
        }
        guard var attempt = activeAttempt else { return }

        if let rawAngle = analysis.measuredAngle, rawAngle.isFinite {
            attempt.minRawAngle = min(attempt.minRawAngle ?? rawAngle, rawAngle)
        }
        if let smoothedAngle = analysis.smoothedAngle, smoothedAngle.isFinite {
            attempt.minSmoothedAngle = min(attempt.minSmoothedAngle ?? smoothedAngle, smoothedAngle)
        }
        if let heightRatio = analysis.hipKneeHeightRatio, heightRatio.isFinite {
            attempt.minHipKneeHeightRatio = min(attempt.minHipKneeHeightRatio ?? heightRatio, heightRatio)
        }
        if let latestPoseInterval, latestPoseInterval.isFinite, latestPoseInterval >= 0 {
            attempt.maxPoseInterval = max(attempt.maxPoseInterval ?? latestPoseInterval, latestPoseInterval)
        }
        if phaseBefore == .standing {
            attempt.maxDepthFrames = max(attempt.maxDepthFrames, framesAfter)
            if phaseAfter == .standing, framesBefore > 0, framesAfter == 0 {
                let breakReason: SquatDepthBreak?
                switch decision {
                case .awaitingDepth: breakReason = .kneeAngle
                case .awaitingHipKneeDepth: breakReason = .hipHeight
                default: breakReason = nil
                }
                if let breakReason {
                    attempt.depthBreakCount += 1
                    attempt.lastBreak = breakReason
                }
            }
        }
        if phaseAfter == .lowered { attempt.depthConfirmed = true }
        activeAttempt = attempt

        if counted {
            complete(.counted)
        } else if decision == .invalidMeasurement {
            interrupt(.invalidMeasurement, breakReason: .invalidMeasurement)
        } else if phaseBefore == .standing,
                  phaseAfter == .standing,
                  let rawAngle = analysis.measuredAngle,
                  let smoothedAngle = analysis.smoothedAngle,
                  rawAngle >= standingThreshold,
                  smoothedAngle >= standingThreshold {
            returnStandingFrames += 1
            if returnStandingFrames >= 3 {
                complete(.returnedWithoutDepth)
            }
        } else {
            returnStandingFrames = 0
        }
    }

    mutating func interrupt(
        _ outcome: SquatDepthOutcome,
        breakReason: SquatDepthBreak? = nil,
        observedGap: TimeInterval? = nil
    ) {
        guard var attempt = activeAttempt else { return }
        if let interval = observedGap ?? latestPoseInterval, interval.isFinite, interval >= 0 {
            attempt.maxPoseInterval = max(attempt.maxPoseInterval ?? interval, interval)
        }
        if let breakReason, attempt.maxDepthFrames > 0 {
            attempt.depthBreakCount += 1
            attempt.lastBreak = breakReason
        }
        activeAttempt = attempt
        complete(outcome)
    }

    private mutating func complete(_ outcome: SquatDepthOutcome) {
        guard var attempt = activeAttempt else { return }
        attempt.outcome = outcome
        lastAttempt = attempt
        recentAttempts.append(attempt)
        if recentAttempts.count > 20 { recentAttempts.removeFirst() }
        activeAttempt = nil
        returnStandingFrames = 0
    }
}


enum Vision3DExperimentalDecision: Equatable {
    case waitingForSample
    case awaitingLegEvidence
    case awaitingStanding
    case confirmingStanding
    case standingConfirmed
    case awaitingDepth
    case insufficientDescent
    case confirmingDepth
    case loweredConfirmed
    case awaitingReturn
    case confirmingReturn
    case counted
    case invalidMeasurement
    case observationGap
    case loweredTimeout
}

enum Vision3DAttemptOutcome: Equatable {
    case counted
    case returnedWithoutDepth
    case loweredTimeout
    case invalidMeasurement
    case observationGap
    case trackingReset
}

struct Vision3DAttempt {
    let number: Int
    let selectedLeg: BodyLeg
    var minimumKneeAngle: Double
    var maximumRelativeDescent: Double
    var loweredDuration: TimeInterval?
    var outcome: Vision3DAttemptOutcome?
}

enum Vision3DLegSelectionSource: Equatable {
    case awaitingEvidence
    case twoDimensionalConfidence
    case singleThreeDimensionalLeg
}

struct Vision3DExperimentalCounter {
    private(set) var repetitions = 0
    private(set) var phase: SquatPhase = .seekingStanding
    private(set) var decision: Vision3DExperimentalDecision = .waitingForSample
    private(set) var selectedLeg: BodyLeg?
    private(set) var selectionSource: Vision3DLegSelectionSource = .awaitingEvidence
    private(set) var leftTwoDimensionalConfidence: Double?
    private(set) var rightTwoDimensionalConfidence: Double?
    private(set) var standingHipKneeRatio: Double?
    private(set) var relativeDescent: Double?
    private(set) var interruptions = 0
    private(set) var activeAttempt: Vision3DAttempt?
    private(set) var lastAttempt: Vision3DAttempt?
    private(set) var recentAttempts: [Vision3DAttempt] = []

    let standingAngle = 135.0
    let loweredAngle = 110.0
    let minimumStandingHipKneeRatio = 0.70
    let minimumRelativeDescent = 0.55
    let maximumSampleGap: TimeInterval = 0.75
    let maximumLoweredDuration: TimeInterval = 5
    let minimumConfirmationDuration: TimeInterval = 0.12
    let requiredConfirmationSamples = 2

    private var lastSampleTime: TimeInterval?
    private var confirmationStartedAt: TimeInterval?
    private var confirmationSamples = 0
    private var candidateStandingRatio: Double?
    private var pendingLeg: BodyLeg?
    private var pendingSelectionSource: Vision3DLegSelectionSource = .awaitingEvidence
    private var loweredStartedAt: TimeInterval?
    private var attemptNumber = 0
    private var returnConfirmationStartedAt: TimeInterval?
    private var returnConfirmationSamples = 0

    mutating func process(
        _ probe: Vision3DProbe,
        at timestamp: TimeInterval,
        leftTwoDimensionalConfidence: Double? = nil,
        rightTwoDimensionalConfidence: Double? = nil,
        preferredTwoDimensionalLeg: BodyLeg? = nil
    ) -> Bool {
        guard probe.threeDimensionalLatencyMs != nil else { return false }
        guard timestamp.isFinite, timestamp >= 0 else {
            interrupt(.invalidMeasurement)
            return false
        }
        if let lastSampleTime, timestamp <= lastSampleTime { return false }
        if isLoweredTimedOut(at: timestamp) {
            interrupt(.loweredTimeout, at: timestamp)
            return false
        }
        if let lastSampleTime, timestamp - lastSampleTime > maximumSampleGap {
            interrupt(.observationGap, at: timestamp)
        }
        lastSampleTime = timestamp

        guard probe.observationAvailable else {
            interrupt(.invalidMeasurement, at: timestamp)
            return false
        }
        let leftMeasurement = validMeasurement(
            angle: probe.leftKneeAngle,
            heightRatio: probe.leftHipKneeHeightRatio
        )
        let rightMeasurement = validMeasurement(
            angle: probe.rightKneeAngle,
            heightRatio: probe.rightHipKneeHeightRatio
        )
        self.leftTwoDimensionalConfidence = validatedConfidence(leftTwoDimensionalConfidence)
        self.rightTwoDimensionalConfidence = validatedConfidence(rightTwoDimensionalConfidence)

        let activeLeg: BodyLeg
        if let selectedLeg {
            activeLeg = selectedLeg
        } else {
            guard let candidate = initialLeg(
                leftMeasurementAvailable: leftMeasurement != nil,
                rightMeasurementAvailable: rightMeasurement != nil,
                preferredTwoDimensionalLeg: preferredTwoDimensionalLeg
            ) else {
                clearStandingConfirmation()
                decision = .awaitingLegEvidence
                return false
            }
            if pendingLeg != candidate.chosenLeg {
                clearStandingConfirmation()
                pendingLeg = candidate.chosenLeg
            }
            pendingSelectionSource = candidate.source
            activeLeg = candidate.chosenLeg
        }

        let measurement = activeLeg == .left ? leftMeasurement : rightMeasurement
        guard let measurement else {
            interrupt(.invalidMeasurement, at: timestamp)
            return false
        }

        let angle = measurement.angle
        let heightRatio = measurement.heightRatio
        relativeDescent = standingHipKneeRatio.map { $0 - heightRatio }
        updateAttempt(
            kneeAngle: angle,
            relativeDescent: relativeDescent,
            timestamp: timestamp,
            selectedLeg: activeLeg
        )

        switch phase {
        case .seekingStanding:
            let isStanding = angle >= standingAngle
                && heightRatio >= minimumStandingHipKneeRatio
            if isStanding {
                candidateStandingRatio = max(
                    candidateStandingRatio ?? heightRatio,
                    heightRatio
                )
            } else {
                candidateStandingRatio = nil
            }
            guard confirm(isStanding, at: timestamp) else {
                decision = isStanding ? .confirmingStanding : .awaitingStanding
                return false
            }
            standingHipKneeRatio = candidateStandingRatio
            candidateStandingRatio = nil
            relativeDescent = 0
            selectedLeg = activeLeg
            selectionSource = pendingSelectionSource
            pendingLeg = nil
            phase = .standing
            decision = .standingConfirmed
        case .standing:
            guard let standingHipKneeRatio else {
                interrupt(.invalidMeasurement, at: timestamp)
                return false
            }
            updateReturnedWithoutDepth(
                angle: angle,
                heightRatio: heightRatio,
                standingHeightRatio: standingHipKneeRatio,
                timestamp: timestamp
            )
            let hasDepth = angle <= loweredAngle
                && standingHipKneeRatio - heightRatio >= minimumRelativeDescent
            guard confirm(hasDepth, at: timestamp) else {
                if angle > loweredAngle {
                    decision = .awaitingDepth
                } else if !hasDepth {
                    decision = .insufficientDescent
                } else {
                    decision = .confirmingDepth
                }
                return false
            }
            phase = .lowered
            loweredStartedAt = timestamp
            if var activeAttempt {
                activeAttempt.loweredDuration = 0
                self.activeAttempt = activeAttempt
            }
            decision = .loweredConfirmed
        case .lowered:
            guard let standingHipKneeRatio else {
                interrupt(.invalidMeasurement, at: timestamp)
                return false
            }
            let returnedStanding = angle >= standingAngle
                && heightRatio >= standingHipKneeRatio - 0.20
            guard confirm(returnedStanding, at: timestamp) else {
                decision = returnedStanding ? .confirmingReturn : .awaitingReturn
                return false
            }
            repetitions += 1
            finishAttempt(.counted, at: timestamp)
            loweredStartedAt = nil
            phase = .standing
            decision = .counted
            self.standingHipKneeRatio = max(standingHipKneeRatio, heightRatio)
            relativeDescent = 0
            return true
        }
        return false
    }

    mutating func expire(at timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        if isLoweredTimedOut(at: timestamp) {
            interrupt(.loweredTimeout, at: timestamp)
            return
        }
        guard let lastSampleTime,
              timestamp - lastSampleTime > maximumSampleGap else { return }
        interrupt(.observationGap, at: timestamp)
    }

    mutating func resetMovement() {
        finishAttempt(.trackingReset, at: lastSampleTime)
        clearMovementState()
    }

    private mutating func clearMovementState() {
        phase = .seekingStanding
        decision = .waitingForSample
        selectedLeg = nil
        selectionSource = .awaitingEvidence
        leftTwoDimensionalConfidence = nil
        rightTwoDimensionalConfidence = nil
        pendingLeg = nil
        pendingSelectionSource = .awaitingEvidence
        standingHipKneeRatio = nil
        relativeDescent = nil
        lastSampleTime = nil
        confirmationSamples = 0
        confirmationStartedAt = nil
        candidateStandingRatio = nil
        loweredStartedAt = nil
        returnConfirmationStartedAt = nil
        returnConfirmationSamples = 0
        activeAttempt = nil
    }

    mutating func reset() {
        clearMovementState()
        repetitions = 0
        interruptions = 0
        attemptNumber = 0
        lastAttempt = nil
        recentAttempts.removeAll(keepingCapacity: true)
    }

    private mutating func interrupt(
        _ reason: Vision3DExperimentalDecision,
        at timestamp: TimeInterval? = nil
    ) {
        if selectedLeg != nil || phase != .seekingStanding {
            interruptions += 1
        }
        let outcome: Vision3DAttemptOutcome
        switch reason {
        case .loweredTimeout: outcome = .loweredTimeout
        case .observationGap: outcome = .observationGap
        default: outcome = .invalidMeasurement
        }
        finishAttempt(outcome, at: timestamp ?? lastSampleTime)
        clearMovementState()
        decision = reason
    }

    private func isLoweredTimedOut(at timestamp: TimeInterval) -> Bool {
        guard phase == .lowered, let loweredStartedAt else { return false }
        return timestamp - loweredStartedAt > maximumLoweredDuration
    }

    private mutating func updateAttempt(
        kneeAngle: Double,
        relativeDescent: Double?,
        timestamp: TimeInterval,
        selectedLeg: BodyLeg
    ) {
        if phase == .standing, kneeAngle < standingAngle, activeAttempt == nil {
            attemptNumber += 1
            activeAttempt = Vision3DAttempt(
                number: attemptNumber,
                selectedLeg: selectedLeg,
                minimumKneeAngle: kneeAngle,
                maximumRelativeDescent: relativeDescent ?? 0,
                loweredDuration: nil,
                outcome: nil
            )
        }
        guard var attempt = activeAttempt else { return }
        attempt.minimumKneeAngle = min(attempt.minimumKneeAngle, kneeAngle)
        if let relativeDescent, relativeDescent.isFinite {
            attempt.maximumRelativeDescent = max(
                attempt.maximumRelativeDescent,
                relativeDescent
            )
        }
        if let loweredStartedAt {
            attempt.loweredDuration = max(0, timestamp - loweredStartedAt)
        }
        activeAttempt = attempt
    }

    private mutating func updateReturnedWithoutDepth(
        angle: Double,
        heightRatio: Double,
        standingHeightRatio: Double,
        timestamp: TimeInterval
    ) {
        guard activeAttempt != nil else { return }
        let returnedStanding = angle >= standingAngle
            && heightRatio >= standingHeightRatio - 0.20
        guard returnedStanding else {
            returnConfirmationStartedAt = nil
            returnConfirmationSamples = 0
            return
        }
        if returnConfirmationStartedAt == nil {
            returnConfirmationStartedAt = timestamp
        }
        returnConfirmationSamples += 1
        if returnConfirmationSamples >= requiredConfirmationSamples,
           timestamp - (returnConfirmationStartedAt ?? timestamp) >= minimumConfirmationDuration {
            finishAttempt(.returnedWithoutDepth, at: timestamp)
        }
    }

    private mutating func finishAttempt(
        _ outcome: Vision3DAttemptOutcome,
        at timestamp: TimeInterval?
    ) {
        guard var attempt = activeAttempt else { return }
        if let loweredStartedAt, let timestamp, timestamp.isFinite {
            attempt.loweredDuration = max(0, timestamp - loweredStartedAt)
        }
        attempt.outcome = outcome
        lastAttempt = attempt
        recentAttempts.append(attempt)
        if recentAttempts.count > 20 { recentAttempts.removeFirst() }
        activeAttempt = nil
        returnConfirmationStartedAt = nil
        returnConfirmationSamples = 0
    }

    private mutating func confirm(_ satisfies: Bool, at timestamp: TimeInterval) -> Bool {
        guard satisfies else {
            confirmationSamples = 0
            confirmationStartedAt = nil
            return false
        }
        if confirmationStartedAt == nil {
            confirmationStartedAt = timestamp
        }
        confirmationSamples += 1
        guard confirmationSamples >= requiredConfirmationSamples,
              timestamp - (confirmationStartedAt ?? timestamp) >= minimumConfirmationDuration
        else { return false }
        confirmationSamples = 0
        confirmationStartedAt = nil
        return true
    }

    private mutating func clearStandingConfirmation() {
        pendingLeg = nil
        pendingSelectionSource = .awaitingEvidence
        candidateStandingRatio = nil
        confirmationSamples = 0
        confirmationStartedAt = nil
    }

    private func validatedConfidence(_ confidence: Double?) -> Double? {
        guard let confidence, confidence.isFinite,
              (0.5...1).contains(confidence) else { return nil }
        return confidence
    }

    private func initialLeg(
        leftMeasurementAvailable: Bool,
        rightMeasurementAvailable: Bool,
        preferredTwoDimensionalLeg: BodyLeg?
    ) -> (chosenLeg: BodyLeg, source: Vision3DLegSelectionSource)? {
        if leftMeasurementAvailable, !rightMeasurementAvailable {
            if preferredTwoDimensionalLeg == .right,
               rightTwoDimensionalConfidence != nil { return nil }
            return (.left, .singleThreeDimensionalLeg)
        }
        if rightMeasurementAvailable, !leftMeasurementAvailable {
            if preferredTwoDimensionalLeg == .left,
               leftTwoDimensionalConfidence != nil { return nil }
            return (.right, .singleThreeDimensionalLeg)
        }
        guard leftMeasurementAvailable, rightMeasurementAvailable else { return nil }

        if preferredTwoDimensionalLeg == .left, leftTwoDimensionalConfidence != nil {
            return (.left, .twoDimensionalConfidence)
        }
        if preferredTwoDimensionalLeg == .right, rightTwoDimensionalConfidence != nil {
            return (.right, .twoDimensionalConfidence)
        }
        if let leftTwoDimensionalConfidence, let rightTwoDimensionalConfidence {
            guard abs(leftTwoDimensionalConfidence - rightTwoDimensionalConfidence) >= 0.05 else {
                return nil
            }
            return leftTwoDimensionalConfidence > rightTwoDimensionalConfidence
                ? (.left, .twoDimensionalConfidence)
                : (.right, .twoDimensionalConfidence)
        }
        if leftTwoDimensionalConfidence != nil {
            return (.left, .twoDimensionalConfidence)
        }
        if rightTwoDimensionalConfidence != nil {
            return (.right, .twoDimensionalConfidence)
        }
        return nil
    }

    private func validMeasurement(
        angle: Double?,
        heightRatio: Double?
    ) -> (angle: Double, heightRatio: Double)? {
        guard let angle, let heightRatio,
              angle.isFinite, heightRatio.isFinite,
              (0...180).contains(angle),
              (-1...1).contains(heightRatio) else { return nil }
        return (angle, heightRatio)
    }
}

#endif

@MainActor
final class WorkoutViewModel {
    var onChange: ((WorkoutViewState) -> Void)?
    private(set) var finishedSummary: WorkoutSummary?

    #if DEBUG
    var onDiagnosticsChange: ((SquatDiagnostics) -> Void)?
    private(set) var latestDiagnostics: SquatDiagnostics?
    private var latestAnalysis: PoseAnalysis?
    private var trackingReset: SquatTrackingReset?
    private var measurementLossCount = 0
    private var legChangeCount = 0
    private var observationGapCount = 0
    private var latestMeasurementIssue: LegMeasurementIssue?
    private var depthAttemptTracker = SquatDepthAttemptTracker()
    private var latestVision2DLatencyMs: Double?
    private var latestVision3DProbe: Vision3DProbe?
    private var latestVision3DSynchronizedPair: Vision3DSynchronizedPair?
    private var vision3DExperimentalCounter = Vision3DExperimentalCounter()
    private var vision3DReturnShadow = Vision3DReturnShadow()
    #endif

    private let persistence: any WorkoutStoring
    private let timeSource: any WorkoutTimeSource
    private let analyzer = PoseAnalyzer()
    private var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
    private var updateTask: Task<Void, Never>?
    private var startedAt: Date
    private var activeStartedAt: TimeInterval?
    private var accumulatedActiveTime: TimeInterval = 0
    private var restDeadline: TimeInterval?
    private var completedSets = 0
    private var totalRepetitions = 0
    private var currentSet = 1
    private(set) var isPaused = false
    private(set) var hasStarted = false
    let startsAutomatically: Bool
    private var isCameraReady: Bool
    private var isFinished = false
    private var hasPose = false
    private var lastPoseTime: TimeInterval?
    private let maximumPoseInterval: TimeInterval = 0.25
    private var saveState: WorkoutSaveState = .notSaved

    let targetRepetitions = 12
    let targetSets = 4
    let restDuration = 60

    init(
        persistence: any WorkoutStoring,
        timeSource: (any WorkoutTimeSource)? = nil,
        cameraReady: Bool = true,
        startsAutomatically: Bool = true
    ) {
        let source = timeSource ?? SystemWorkoutTimeSource()
        self.persistence = persistence
        self.timeSource = source
        self.startsAutomatically = startsAutomatically
        startedAt = source.date
        isCameraReady = cameraReady
        hasStarted = startsAutomatically && cameraReady
        isPaused = !hasStarted
        activeStartedAt = hasStarted ? source.currentTime : nil
        startUpdates()
    }

    deinit {
        updateTask?.cancel()
    }

    #if DEBUG
    func clearVision3DComparison() {
        latestVision3DProbe = nil
        latestVision3DSynchronizedPair = nil
        vision3DExperimentalCounter.reset()
        vision3DReturnShadow.reset()
        publish()
    }
    #endif

    func process(_ pose: BodyPose?) {
        guard !isPaused, !isFinished else { return }
        let currentTime = timeSource.currentTime
        let activeTime = activeDuration(at: currentTime)
        advanceRest(at: activeTime)
        guard restDeadline == nil else { return }
        #if DEBUG
        depthAttemptTracker.recordPose(at: currentTime)
        vision3DExperimentalCounter.expire(at: currentTime)
        vision3DReturnShadow.expire(at: currentTime)
        #endif
        expireTracking(at: currentTime)
        let analysis = analyzer.analyze(pose)
        #if DEBUG
        latestVision2DLatencyMs = pose?.vision3DProbe?.twoDimensionalLatencyMs
        latestVision3DProbe = pose?.vision3DProbe
        if let probe = pose?.vision3DProbe,
           probe.threeDimensionalLatencyMs != nil {
            latestVision3DSynchronizedPair = Vision3DSynchronizedPair(
                sampleNumber: probe.sampleCount,
                selectedLeg: analysis.selectedLeg,
                twoDimensionalLeftAngle: analysis.leftMeasurement.isReliable
                    ? analysis.leftMeasurement.angle : nil,
                twoDimensionalRightAngle: analysis.rightMeasurement.isReliable
                    ? analysis.rightMeasurement.angle : nil,
                twoDimensionalSelectedHeightRatio: analysis.hipKneeHeightRatio,
                probe: probe
            )
            if Vision3DProbeControl.isEnabled {
                _ = vision3DExperimentalCounter.process(
                    probe,
                    at: currentTime,
                    leftTwoDimensionalConfidence: analysis.leftMeasurement.isReliable
                        ? Double(analysis.leftMeasurement.confidence) : nil,
                    rightTwoDimensionalConfidence: analysis.rightMeasurement.isReliable
                        ? Double(analysis.rightMeasurement.confidence) : nil,
                    preferredTwoDimensionalLeg: analysis.selectedLeg
                )
                vision3DReturnShadow.observe(
                    probe,
                    at: currentTime,
                    threeDimensionalLeg: vision3DExperimentalCounter.selectedLeg,
                    standingReference: vision3DExperimentalCounter.standingHipKneeRatio,
                    twoDimensionalLeg: analysis.selectedLeg,
                    twoDimensionalLeftAngle: analysis.leftMeasurement.isReliable
                        ? analysis.leftMeasurement.angle : nil,
                    twoDimensionalRightAngle: analysis.rightMeasurement.isReliable
                        ? analysis.rightMeasurement.angle : nil,
                    twoDimensionalSelectedHipKneeRatio: analysis.hipKneeHeightRatio
                )
            }
        }
        #endif
        hasPose = analysis.smoothedAngle != nil
        lastPoseTime = hasPose ? currentTime : nil
        #if DEBUG
        if analysis.requiresMovementReset, counter.phase != .seekingStanding {
            if analysis.selectedLeg == nil {
                measurementLossCount += 1
                latestMeasurementIssue = trackingIssue(for: analysis)
            } else {
                legChangeCount += 1
            }
        }
        #endif
        #if DEBUG
        if analysis.requiresMovementReset {
            if analysis.selectedLeg == nil {
                depthAttemptTracker.interrupt(.measurementLost, breakReason: .measurementLost)
            } else {
                depthAttemptTracker.interrupt(.legChanged, breakReason: .legChanged)
            }
        }
        #endif
        if analysis.requiresMovementReset { counter.resetMovement() }
        #if DEBUG
        latestAnalysis = analysis
        if analysis.requiresMovementReset {
            trackingReset = analysis.selectedLeg == nil ? .measurementLost : .legChanged
        }
        #endif

        #if DEBUG
        let phaseBefore = counter.phase
        let framesBefore = counter.consecutiveFrames
        #endif
        let counted = counter.process(
            measuredAngle: analysis.measuredAngle,
            smoothedAngle: analysis.smoothedAngle,
            hipKneeHeightRatio: analysis.hipKneeHeightRatio
        )
        #if DEBUG
        depthAttemptTracker.observe(
            analysis: analysis,
            phaseBefore: phaseBefore,
            phaseAfter: counter.phase,
            framesBefore: framesBefore,
            framesAfter: counter.consecutiveFrames,
            decision: counter.decision,
            counted: counted,
            standingThreshold: counter.standingThreshold
        )
        if counter.phase != .seekingStanding { trackingReset = nil }
        #endif
        if counted {
            totalRepetitions += 1
            if counter.repetitions >= targetRepetitions {
                completedSets += 1
                if completedSets == targetSets {
                    finish()
                    return
                }
                restDeadline = activeTime + TimeInterval(restDuration)
                counter.reset()
                resetTracking()
            }
        }
        publish(activeTime: activeTime)
    }

    func togglePause() {
        if isPaused { resume() }
        else { pause() }
    }

    func observePose(_ pose: BodyPose?) {
        guard isPaused, !isFinished else { return }
        let detected = pose != nil
        guard hasPose != detected else { return }
        hasPose = detected
        publish()
    }

    func setCameraReady(_ ready: Bool) {
        isCameraReady = ready
        if !ready {
            #if DEBUG
            depthAttemptTracker.interrupt(.cameraUnavailable)
            #endif
            pause()
            resetTracking()
        }
        publish()
    }

    func pause() {
        guard !isFinished, !isPaused else { return }
        let activeTime = activeDuration(at: timeSource.currentTime)
        advanceRest(at: activeTime)
        accumulatedActiveTime = activeTime
        activeStartedAt = nil
        isPaused = true
        #if DEBUG
        depthAttemptTracker.interrupt(.paused)
        #endif
        resetTracking()
        stopUpdates()
        publish(activeTime: activeTime)
    }

    func resume() {
        guard !isFinished, isPaused, isCameraReady else { return }
        if !hasStarted {
            startedAt = timeSource.date
            hasStarted = true
        }
        resetTracking()
        activeStartedAt = timeSource.currentTime
        isPaused = false
        startUpdates()
        publish()
    }

    func finish() {
        guard !isFinished else { return }
        let activeTime = activeDuration(at: timeSource.currentTime)
        advanceRest(at: activeTime)
        accumulatedActiveTime = activeTime
        activeStartedAt = nil
        finishedSummary = WorkoutSummary(
            date: startedAt,
            duration: max(0, Int(activeTime)),
            repetitions: totalRepetitions,
            sets: min(targetSets, completedSets + (counter.repetitions > 0 ? 1 : 0))
        )
        isFinished = true
        #if DEBUG
        depthAttemptTracker.interrupt(.finished)
        #endif
        stopUpdates()
        retrySave()
    }

    func retrySave() {
        guard let finishedSummary else { return }
        switch saveState {
        case .saving, .saved:
            return
        case .notSaved, .failed:
            break
        }

        saveState = .saving
        publish()
        do {
            try persistence.save(finishedSummary)
            saveState = .saved
        } catch {
            saveState = .failed("Не удалось сохранить тренировку: \(error.localizedDescription)")
        }
        publish()
    }

    var elapsedSeconds: Int {
        if let finishedSummary { return finishedSummary.duration }
        return max(0, Int(activeDuration(at: timeSource.currentTime)))
    }

    func refreshTime() {
        guard !isPaused, !isFinished else { return }
        let currentTime = timeSource.currentTime
        let activeTime = activeDuration(at: currentTime)
        advanceRest(at: activeTime)
        #if DEBUG
        vision3DExperimentalCounter.expire(at: currentTime)
        vision3DReturnShadow.expire(at: currentTime)
        #endif
        expireTracking(at: currentTime)
        publish(activeTime: activeTime)
    }

    private func expireTracking(at currentTime: TimeInterval) {
        guard let lastPoseTime, currentTime - lastPoseTime > maximumPoseInterval else { return }
        #if DEBUG
        if counter.phase != .seekingStanding { observationGapCount += 1 }
        depthAttemptTracker.interrupt(
            .observationGap,
            breakReason: .observationGap,
            observedGap: currentTime - lastPoseTime
        )
        #endif
        resetTracking()
        #if DEBUG
        trackingReset = .observationGap
        #endif
    }

    #if DEBUG
    private func trackingIssue(for analysis: PoseAnalysis) -> LegMeasurementIssue? {
        let issues = [analysis.leftMeasurement.issue, analysis.rightMeasurement.issue]
        if issues.contains(.lowConfidence) { return .lowConfidence }
        if issues.contains(.invalidGeometry) { return .invalidGeometry }
        if issues.contains(.missingJoint) { return .missingJoint }
        return nil
    }
    #endif

    private func resetTracking() {
        #if DEBUG
        depthAttemptTracker.interrupt(.trackingReset)
        depthAttemptTracker.resetPoseClock()
        latestVision2DLatencyMs = nil
        latestVision3DProbe = nil
        latestVision3DSynchronizedPair = nil
        vision3DExperimentalCounter.resetMovement()
        vision3DReturnShadow.reset()
        #endif
        counter.resetMovement()
        analyzer.reset()
        lastPoseTime = nil
        hasPose = false
        #if DEBUG
        latestAnalysis = nil
        trackingReset = nil
        #endif
    }

    private func activeDuration(at currentTime: TimeInterval) -> TimeInterval {
        guard let activeStartedAt else { return accumulatedActiveTime }
        return accumulatedActiveTime + max(0, currentTime - activeStartedAt)
    }

    private func advanceRest(at activeTime: TimeInterval) {
        if !isPaused, !isFinished, let restDeadline, activeTime >= restDeadline {
            self.restDeadline = nil
            currentSet += 1
        }
    }

    private func startUpdates() {
        guard updateTask == nil, !isPaused, !isFinished else { return }
        updateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refreshTime()
            }
        }
    }

    private func stopUpdates() {
        updateTask?.cancel()
        updateTask = nil
    }

    private func publish(activeTime: TimeInterval? = nil) {
        let currentDuration = activeTime ?? activeDuration(at: timeSource.currentTime)
        let remainingRest = restDeadline.map { max(0, Int(ceil($0 - currentDuration))) } ?? 0
        #if DEBUG
        let diagnostics = SquatDiagnostics(
            analysis: latestAnalysis,
            phase: counter.phase,
            decision: counter.decision,
            consecutiveFrames: counter.consecutiveFrames,
            requiredFrames: counter.requiredStableFrames,
            standingThreshold: counter.standingThreshold,
            loweredThreshold: counter.loweredThreshold,
            status: isFinished ? .finished : (!isCameraReady ? .waitingForCamera : (!hasStarted ? .ready : (isPaused ? .paused : (restDeadline != nil ? .resting : .tracking)))),
            resetReason: trackingReset,
            measurementLossCount: measurementLossCount,
            legChangeCount: legChangeCount,
            observationGapCount: observationGapCount,
            latestMeasurementIssue: latestMeasurementIssue,
            activeDepthAttempt: depthAttemptTracker.activeAttempt,
            lastDepthAttempt: depthAttemptTracker.lastAttempt,
            recentDepthAttempts: depthAttemptTracker.recentAttempts,
            vision2DLatencyMs: latestVision2DLatencyMs,
            vision3DProbe: latestVision3DProbe,
            vision3DSynchronizedPair: latestVision3DSynchronizedPair,
            vision3DExperimentalCounter: vision3DExperimentalCounter,
            vision3DReturnShadow: vision3DReturnShadow
        )
        latestDiagnostics = diagnostics
        onDiagnosticsChange?(diagnostics)
        #endif
        onChange?(WorkoutViewState(
            repetitions: counter.repetitions,
            totalRepetitions: totalRepetitions,
            currentSet: currentSet,
            targetSets: targetSets,
            targetRepetitions: targetRepetitions,
            elapsedSeconds: finishedSummary?.duration ?? max(0, Int(currentDuration)),
            remainingRestSeconds: remainingRest,
            isResting: restDeadline != nil,
            isPaused: isPaused,
            hasStarted: hasStarted,
            isFinished: isFinished,
            poseDetected: hasPose,
            saveState: saveState
        ))
    }
}
