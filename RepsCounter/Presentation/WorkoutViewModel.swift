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
    let isFinished: Bool
    let poseDetected: Bool
    let saveState: WorkoutSaveState
}

#if DEBUG
enum SquatTrackingStatus: Equatable {
    case waitingForCamera
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
    #endif

    private let persistence: any WorkoutStoring
    private let timeSource: any WorkoutTimeSource
    private let analyzer = PoseAnalyzer()
    private var counter = SquatCounter()
    private var updateTask: Task<Void, Never>?
    private let startedAt: Date
    private var activeStartedAt: TimeInterval?
    private var accumulatedActiveTime: TimeInterval = 0
    private var restDeadline: TimeInterval?
    private var completedSets = 0
    private var totalRepetitions = 0
    private var currentSet = 1
    private(set) var isPaused = false
    private var isCameraReady: Bool
    private var isFinished = false
    private var hasPose = false
    private var lastPoseTime: TimeInterval?
    private let maximumPoseInterval: TimeInterval = 0.25
    private var saveState: WorkoutSaveState = .notSaved

    let targetRepetitions = 12
    let targetSets = 4
    let restDuration = 60

    init(persistence: any WorkoutStoring, timeSource: (any WorkoutTimeSource)? = nil, cameraReady: Bool = true) {
        let source = timeSource ?? SystemWorkoutTimeSource()
        self.persistence = persistence
        self.timeSource = source
        startedAt = source.date
        isCameraReady = cameraReady
        isPaused = !cameraReady
        activeStartedAt = cameraReady ? source.currentTime : nil
        startUpdates()
    }

    deinit {
        updateTask?.cancel()
    }

    func process(_ pose: BodyPose?) {
        guard !isPaused, !isFinished else { return }
        let currentTime = timeSource.currentTime
        let activeTime = activeDuration(at: currentTime)
        advanceRest(at: activeTime)
        guard restDeadline == nil else { return }
        expireTracking(at: currentTime)
        let analysis = analyzer.analyze(pose)
        hasPose = analysis.smoothedAngle != nil
        lastPoseTime = hasPose ? currentTime : nil
        if analysis.requiresMovementReset { counter.resetMovement() }
        #if DEBUG
        latestAnalysis = analysis
        if analysis.requiresMovementReset {
            trackingReset = analysis.selectedLeg == nil ? .measurementLost : .legChanged
        }
        #endif

        let counted = counter.process(angle: analysis.smoothedAngle)
        #if DEBUG
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

    func setCameraReady(_ ready: Bool) {
        isCameraReady = ready
        if !ready { pause() }
        publish()
    }

    func pause() {
        guard !isFinished, !isPaused else { return }
        let activeTime = activeDuration(at: timeSource.currentTime)
        advanceRest(at: activeTime)
        accumulatedActiveTime = activeTime
        activeStartedAt = nil
        isPaused = true
        resetTracking()
        stopUpdates()
        publish(activeTime: activeTime)
    }

    func resume() {
        guard !isFinished, isPaused, isCameraReady else { return }
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
        publish(activeTime: activeTime)
    }

    private func expireTracking(at currentTime: TimeInterval) {
        guard let lastPoseTime, currentTime - lastPoseTime > maximumPoseInterval else { return }
        resetTracking()
        #if DEBUG
        trackingReset = .observationGap
        #endif
    }

    private func resetTracking() {
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
            status: isFinished ? .finished : (!isCameraReady ? .waitingForCamera : (isPaused ? .paused : (restDeadline != nil ? .resting : .tracking))),
            resetReason: trackingReset
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
            isFinished: isFinished,
            poseDetected: hasPose,
            saveState: saveState
        ))
    }
}
