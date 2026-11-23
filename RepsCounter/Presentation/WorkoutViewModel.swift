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

struct WorkoutViewState: Equatable {
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

struct PoseFrameRateTracker {
    private var recentTimestamps: [TimeInterval] = []
    private(set) var rate: Double?

    mutating func record(at timestamp: TimeInterval) {
        guard timestamp.isFinite, timestamp >= 0 else { return }
        if let previous = recentTimestamps.last {
            if timestamp == previous { return }
            if timestamp < previous { reset() }
        }
        recentTimestamps.append(timestamp)
        while let first = recentTimestamps.first, timestamp - first > 1 {
            recentTimestamps.removeFirst()
        }
        guard let first = recentTimestamps.first,
              recentTimestamps.count >= 2,
              timestamp - first >= 0.5 else {
            rate = nil
            return
        }
        rate = Double(recentTimestamps.count - 1) / (timestamp - first)
    }

    mutating func reset() {
        recentTimestamps.removeAll()
        rate = nil
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
    let poseFramesPerSecond: Double?
    let bilateral: BilateralCounterTelemetry?
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

#endif

@MainActor
final class WorkoutViewModel {
    var onChange: ((WorkoutViewState) -> Void)? {
        didSet { lastPublishedState = nil }
    }
    private var lastPublishedState: WorkoutViewState?
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
    private var poseFrameRate = PoseFrameRateTracker()
    #endif
    private var bilateralCounter = BilateralLiveCounter()
    private(set) var usesBilateralCounting = false

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

    @discardableResult
    func setBilateralCountingEnabled(_ enabled: Bool) -> Bool {
        guard !hasStarted, !isFinished else { return false }
        usesBilateralCounting = enabled
        bilateralCounter.reset()
        counter.reset()
        resetTracking()
        publish()
        return true
    }

    private var repetitionsInSet: Int {
        if usesBilateralCounting { return bilateralCounter.repetitions }
        return counter.repetitions
    }

    func process(_ pose: BodyPose?) {
        guard !isPaused, !isFinished else { return }
        let currentTime = timeSource.currentTime
        let activeTime = activeDuration(at: currentTime)
        advanceRest(at: activeTime)
        guard restDeadline == nil else { return }
        #if DEBUG
        depthAttemptTracker.recordPose(at: currentTime)
        poseFrameRate.record(at: currentTime)
        #endif
        expireTracking(at: currentTime)
        let analysis = analyzer.analyze(pose)
        hasPose = analysis.smoothedAngle != nil
        lastPoseTime = hasPose ? currentTime : nil
        #if DEBUG
        if analysis.didSwitchLeg {
            legChangeCount += 1
        } else if analysis.requiresMovementReset,
                  analysis.selectedLeg == nil,
                  counter.phase != .seekingStanding {
            measurementLossCount += 1
            latestMeasurementIssue = trackingIssue(for: analysis)
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
        let newRepetitions = usesBilateralCounting
            ? bilateralCounter.process(pose, at: currentTime) : (counted ? 1 : 0)
        if applyNewRepetitions(newRepetitions, activeTime: activeTime) { return }
        publish(activeTime: activeTime)
    }

    @discardableResult
    private func applyNewRepetitions(_ amount: Int, activeTime: TimeInterval) -> Bool {
        guard amount > 0 else { return false }
        totalRepetitions += amount
        if repetitionsInSet >= targetRepetitions {
            completedSets += 1
            if completedSets >= targetSets {
                finish()
                return true
            }
            restDeadline = activeTime + TimeInterval(restDuration)
            counter.reset()
            bilateralCounter.reset()
            resetTracking()
        }
        return false
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
        if usesBilateralCounting {
            let pendingRepetitions = bilateralCounter.finishPending()
            if applyNewRepetitions(pendingRepetitions, activeTime: activeTime) { return }
        }
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
        if usesBilateralCounting {
            totalRepetitions += bilateralCounter.finishPending()
        }
        accumulatedActiveTime = activeTime
        activeStartedAt = nil
        finishedSummary = WorkoutSummary(
            date: startedAt,
            duration: max(0, Int(activeTime)),
            repetitions: totalRepetitions,
            sets: min(targetSets, completedSets + (repetitionsInSet > 0 ? 1 : 0))
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
        expireTracking(at: currentTime)
        if usesBilateralCounting, restDeadline == nil {
            let newRepetitions = bilateralCounter.flush(at: currentTime)
            if applyNewRepetitions(newRepetitions, activeTime: activeTime) { return }
        }
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
        poseFrameRate.reset()
        #endif
        counter.resetMovement()
        bilateralCounter.resetMovement()
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
            poseFramesPerSecond: poseFrameRate.rate,
            bilateral: usesBilateralCounting ? bilateralCounter.telemetry : nil
        )
        latestDiagnostics = diagnostics
        onDiagnosticsChange?(diagnostics)
        #endif
        let nextState = WorkoutViewState(
            repetitions: repetitionsInSet,
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
        )
        guard lastPublishedState != nextState else { return }
        lastPublishedState = nextState
        onChange?(nextState)
    }
}
