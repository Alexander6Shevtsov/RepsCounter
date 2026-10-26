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

@MainActor
final class WorkoutViewModel {
    var onChange: ((WorkoutViewState) -> Void)?
    private(set) var finishedSummary: WorkoutSummary?

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
        let activeTime = activeDuration(at: timeSource.currentTime)
        advanceRest(at: activeTime)
        guard restDeadline == nil else { return }
        let measuredAngle = pose.flatMap { analyzer.kneeAngle(from: $0) }
        hasPose = measuredAngle != nil
        if pose == nil { analyzer.reset() }

        if counter.process(angle: measuredAngle) {
            totalRepetitions += 1
            if counter.repetitions >= targetRepetitions {
                completedSets += 1
                if completedSets == targetSets {
                    finish()
                    return
                }
                restDeadline = activeTime + TimeInterval(restDuration)
                counter.reset()
                analyzer.reset()
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
        counter.resetMovement()
        analyzer.reset()
        hasPose = false
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
        let activeTime = activeDuration(at: timeSource.currentTime)
        advanceRest(at: activeTime)
        publish(activeTime: activeTime)
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
