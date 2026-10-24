import Foundation

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
}

@MainActor
final class WorkoutViewModel {
    var onChange: ((WorkoutViewState) -> Void)?
    var onFailure: ((String) -> Void)?

    private let persistence: WorkoutPersistence
    private let analyzer = PoseAnalyzer()
    private var counter = SquatCounter()
    private var timer: Timer?
    private let startedAt = Date()
    private var pausedAt: Date?
    private var totalPausedTime: TimeInterval = 0
    private var restDeadline: Date?
    private var completedSets = 0
    private var totalRepetitions = 0
    private var currentSet = 1
    private var isPaused = false
    private var isFinished = false
    private var hasPose = false

    let targetRepetitions = 12
    let targetSets = 4
    let restDuration = 60

    init(persistence: WorkoutPersistence) {
        self.persistence = persistence
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func process(_ pose: BodyPose?) {
        guard !isPaused, !isFinished, restDeadline == nil else { return }
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
                restDeadline = Date().addingTimeInterval(TimeInterval(restDuration))
                counter.reset()
                analyzer.reset()
            }
        }
        publish()
    }

    func togglePause() {
        guard !isFinished else { return }
        isPaused.toggle()
        if isPaused {
            pausedAt = Date()
        } else if let pausedAt {
            let pausedTime = Date().timeIntervalSince(pausedAt)
            totalPausedTime += pausedTime
            if let restDeadline { self.restDeadline = restDeadline.addingTimeInterval(pausedTime) }
            self.pausedAt = nil
        }
        publish()
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        timer?.invalidate()
        timer = nil
        let summary = WorkoutSummary(
            date: startedAt,
            duration: elapsedSeconds,
            repetitions: totalRepetitions,
            sets: min(targetSets, completedSets + (counter.repetitions > 0 ? 1 : 0))
        )
        do {
            try persistence.save(summary)
        } catch {
            onFailure?("Не удалось сохранить тренировку: \(error.localizedDescription)")
        }
        publish()
    }

    var elapsedSeconds: Int {
        let effectiveNow = pausedAt ?? Date()
        return max(0, Int(effectiveNow.timeIntervalSince(startedAt) - totalPausedTime))
    }

    private func tick() {
        if !isPaused, let restDeadline, Date() >= restDeadline {
            self.restDeadline = nil
            currentSet += 1
        }
        publish()
    }

    private func publish() {
        let remainingRest = restDeadline.map { max(0, Int(ceil($0.timeIntervalSince(Date())))) } ?? 0
        onChange?(WorkoutViewState(
            repetitions: counter.repetitions,
            totalRepetitions: totalRepetitions,
            currentSet: currentSet,
            targetSets: targetSets,
            targetRepetitions: targetRepetitions,
            elapsedSeconds: elapsedSeconds,
            remainingRestSeconds: remainingRest,
            isResting: restDeadline != nil,
            isPaused: isPaused,
            isFinished: isFinished,
            poseDetected: hasPose
        ))
    }
}
