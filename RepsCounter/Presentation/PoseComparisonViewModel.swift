//
//  PoseComparisonViewModel.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

#if DEBUG
import Foundation

@MainActor
final class PoseComparisonViewModel {
    var onChange: (() -> Void)?
    private(set) var isEnabled = false
    private(set) var isRecording = false
    private(set) var latestPlanar: ExperimentFrame2D?
    private(set) var latestPair: PoseComparisonPair?
    private(set) var statistics = ExperimentLoadStatistics()
    private(set) var series: [ExperimentSeries] = []
    private(set) var rejectedResults = 0
    private(set) var productionRepetitions = 0
    var selectedViewpoint: ExperimentViewpoint = .unspecified
    private(set) var firstObservation: ContinuousClock.Instant?
    private(set) var lastObservation: ContinuousClock.Instant?
    private let capture: PoseExperimentCapture?
    private let clock: @MainActor () -> ContinuousClock.Instant
    private var deliveryTask: Task<Void, Never>?
    private var workoutActive = false
    private var previousPairIdentity: ExperimentFrameIdentity?
    private var pairedIdentities: Set<ExperimentFrameIdentity> = []
    private var rateStartedAt: ContinuousClock.Instant?

    init(capture: PoseExperimentCapture?, clock: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.capture = capture
        self.clock = clock
        if let updates = capture?.updates {
            deliveryTask = Task { @MainActor [weak self] in
                for await update in updates {
                    guard !Task.isCancelled else { return }
                    self?.receive(update)
                }
            }
        }
    }

    deinit {
        capture?.setEnabled(false)
        deliveryTask?.cancel()
    }

    var isAvailable: Bool { capture != nil }
    var canStartSeries: Bool { isAvailable && isEnabled && workoutActive }
    var isLatestPairFresh: Bool {
        guard let latestPair else { return false }
        return latestPair.source.metadata.receivedAt.duration(to: clock()) < PoseExperimentCapture.maximumResultAge
    }
    var planarFPS: Double { observationRate(count: statistics.analyzed2D) }
    var spatialFPS: Double { observationRate(count: statistics.completed3D) }
    var usableFPS: Double {
        observationRate(count: statistics.usable3D)
    }

    private func observationRate(count: Int) -> Double {
        guard let rateStartedAt else { return 0 }
        let elapsed = rateStartedAt.duration(to: clock()).experimentSeconds
        return elapsed > 0 ? Double(count) / elapsed : 0
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        capture?.setEnabled(enabled && workoutActive)
        if !enabled {
            finishSeries()
            latestPair = nil
            latestPlanar = nil
        }
        onChange?()
    }

    func updateWorkout(active: Bool, repetitions: Int) {
        productionRepetitions = repetitions
        if workoutActive != active {
            workoutActive = active
            capture?.setEnabled(isEnabled && active)
            latestPair = nil
            latestPlanar = nil
            previousPairIdentity = nil
            if !active { finishSeries() }
        }
        onChange?()
    }

    func startSeries() {
        guard isEnabled, workoutActive, !isRecording else { return }
        capture?.resetSeries()
        latestPair = nil
        latestPlanar = nil
        statistics = ExperimentLoadStatistics()
        firstObservation = nil
        lastObservation = nil
        rateStartedAt = clock()
        pairedIdentities.removeAll()
        previousPairIdentity = nil
        rejectedResults = 0
        if series.count == 12 { series.removeFirst() }
        var nextSeries = ExperimentSeries(id: UUID(), startedAt: clock())
        nextSeries.viewpoint = selectedViewpoint
        nextSeries.productionStartCount = productionRepetitions
        series.append(nextSeries)
        isRecording = true
        onChange?()
    }

    func finishSeries() {
        guard isRecording, !series.isEmpty else { return }
        series[series.count - 1].endedAt = clock()
        series[series.count - 1].productionEndCount = productionRepetitions
        series[series.count - 1].finalStatistics = statistics
        isRecording = false
        onChange?()
    }

    @discardableResult
    func annotate(full: Int, partial: Int, uncertain: Int) -> Bool {
        guard !isRecording, !series.isEmpty,
              full >= 0, partial >= 0, uncertain >= 0,
              full <= 1000, partial <= 1000, uncertain <= 1000 else { return false }
        series[series.count - 1].annotation = ExperimentManualAnnotation(
            fullRepetitions: full, partialRepetitions: partial, uncertainRepetitions: uncertain
        )
        onChange?()
        return true
    }

    func receive(_ update: PoseExperimentUpdate) {
        let source: ExperimentFrame2D
        let counters: ExperimentLoadStatistics
        switch update {
        case .planar(let frame, let statistics): source = frame; counters = statistics
        case .paired(let pair, let statistics): source = pair.source; counters = statistics
        }
        let instant = clock()
        guard isEnabled, workoutActive, capture?.isCurrent(source) == true,
              source.metadata.receivedAt <= instant,
              source.metadata.receivedAt.duration(to: instant) < PoseExperimentCapture.maximumResultAge else {
            rejectedResults += 1
            return
        }
        switch update {
        case .planar(let frame, _):
            if let latestPlanar,
               latestPlanar.metadata.identity.generation == frame.metadata.identity.generation,
               latestPlanar.metadata.identity.sequence >= frame.metadata.identity.sequence {
                rejectedResults += 1
                return
            }
            latestPlanar = frame
            if rateStartedAt == nil { rateStartedAt = source.metadata.receivedAt }
            if firstObservation == nil { firstObservation = source.metadata.receivedAt }
            lastObservation = source.metadata.receivedAt
        case .paired(let pair, _):
            let identity = pair.source.metadata.identity
            guard !pairedIdentities.contains(identity),
                  previousPairIdentity.map({ $0.generation != identity.generation || $0.sequence < identity.sequence }) ?? true else {
                rejectedResults += 1
                return
            }
            pairedIdentities.insert(identity)
            if pairedIdentities.count > 600 { pairedIdentities = [identity] }
            previousPairIdentity = identity
            latestPair = pair
            if isRecording, !series.isEmpty {
                let seriesIndex = series.count - 1
                if series[seriesIndex].pairs.count == 600 {
                    series[seriesIndex].pairs.removeFirst()
                    series[seriesIndex].evictedPairs += 1
                }
                series[seriesIndex].pairs.append(pair)
            }
        }
        statistics = counters
        onChange?()
    }
}
#endif
