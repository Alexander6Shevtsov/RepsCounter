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
    private var saveState: WorkoutSaveState = .notSaved

    let targetRepetitions = 12
    let targetSets = 4
    let restDuration = 60

    init(persistence: any WorkoutStoring) {
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
        finishedSummary = WorkoutSummary(
            date: startedAt,
            duration: elapsedSeconds,
            repetitions: totalRepetitions,
            sets: min(targetSets, completedSets + (counter.repetitions > 0 ? 1 : 0))
        )
        isFinished = true
        timer?.invalidate()
        timer = nil
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
        let effectiveNow = pausedAt ?? Date()
        return max(0, Int(effectiveNow.timeIntervalSince(startedAt) - totalPausedTime))
    }

    private func tick() {
        guard !isFinished else { return }
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
            poseDetected: hasPose,
            saveState: saveState
        ))
    }
}
